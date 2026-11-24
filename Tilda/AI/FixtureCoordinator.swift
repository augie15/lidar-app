import Foundation
import Observation
import simd

/// Owns every scan's fixtures: loads and saves `fixtures.json`, runs photo detection in the background (one scan at a
/// time, cancellable, never on the main thread), and applies the user's edits: adds, moves, kind and length changes,
/// confirmations and deletions (with restore for undo). Every change is saved to `fixtures.json` straight away.
@MainActor
@Observable
final class FixtureCoordinator {
    struct Progress: Equatable { var done: Int; var total: Int }

    private(set) var libraries: [UUID: FixtureLibrary] = [:]
    /// Scans being checked right now. `total` is 0 while queued or preparing.
    private(set) var running: [UUID: Progress] = [:]
    /// Set when a finished run could not read any photo, so the card can say so instead of "none found".
    private(set) var lastRunFailed: Set<UUID> = []

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var attempted: Set<UUID> = []
    @ObservationIgnored private weak var store: ScanStore?

    /// A scan saved this recently counts as "just scanned" and is checked automatically.
    static let freshScanWindow: TimeInterval = 15 * 60

    func library(for id: UUID) -> FixtureLibrary? { libraries[id] }
    func fixtures(for id: UUID) -> [Fixture] { libraries[id]?.fixtures ?? [] }
    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    // MARK: Loading

    func load(_ scan: Scan, store: ScanStore) {
        self.store = store
        if libraries[scan.id] == nil {
            libraries[scan.id] = FixtureLibrary.load(from: store.fixturesURL(for: scan))
        }
    }

    /// Call whenever `store.scans` changes. Checks photos of a Room scan that was just saved, when the on-device model
    /// can read photos, `aiAutoAnalyze` is on, and the scan has never been checked.
    func sync(store: ScanStore, autoDetect: Bool) {
        self.store = store
        let ids = Set(store.scans.map(\.id))
        for gone in libraries.keys where !ids.contains(gone) { libraries[gone] = nil }
        for scan in store.scans where scan.kind == .room {
            load(scan, store: store)
            guard autoDetect, libraries[scan.id]?.detectedAt == nil, !attempted.contains(scan.id),
                  Date.now.timeIntervalSince(scan.createdAt) < Self.freshScanWindow,
                  store.framesURL(for: scan) != nil, FixtureDetectionSupport.isAvailable else { continue }
            detect(scan, store: store)
        }
    }

    // MARK: Detection

    /// "Find fixtures" / "Scan photos again". Fixtures the user has touched are kept (hand-tagged, confirmed or edited);
    /// earlier detections nobody has checked are replaced.
    func detect(_ scan: Scan, store: ScanStore) {
        self.store = store
        guard running[scan.id] == nil, !queue.contains(scan.id) else { return }
        attempted.insert(scan.id)
        lastRunFailed.remove(scan.id)
        queue.append(scan.id)
        running[scan.id] = Progress(done: 0, total: 0)
        startWorker()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if let task = tasks[id] { task.cancel() } else { running[id] = nil }
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let id = self.queue.first {
                self.queue.removeFirst()
                if let scan = self.store?.scans.first(where: { $0.id == id }) {
                    let task = Task { await self.run(scan) }
                    self.tasks[id] = task
                    await task.value
                    self.tasks[id] = nil
                }
                self.running[id] = nil
            }
            self?.worker = nil
        }
    }

    private func run(_ scan: Scan) async {
        guard let store, #available(iOS 27.0, *) else { return }
        guard let framesDir = store.framesURL(for: scan) else { return }
        let planURL = store.floorPlanURL(for: scan)
        let factsURL = store.roomFactsURL(for: scan)
        let id = scan.id
        running[id] = Progress(done: 0, total: 0)

        let work = Task.detached(priority: .utility) {
            let plan = planURL.flatMap { FloorPlan.load(from: $0) }
            let facts = factsURL.flatMap { RoomFacts.load(from: $0) }
            return await FixtureDetector.run(framesDir: framesDir, plan: plan, facts: facts) { done, total in
                await MainActor.run { [weak self] in
                    if self?.running[id] != nil { self?.running[id] = Progress(done: done, total: total) }
                }
            }
        }
        let output = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

        // A cancelled run leaves the saved results untouched.
        guard !output.cancelled else { return }
        var library = libraries[id] ?? FixtureLibrary()
        library.fixtures = library.merging(detections: output.fixtures, radius: FixturePlacement.mergeRadius)
        library.detectedAt = .now
        library.photosChecked = output.photosChecked
        if output.photosChecked == 0 { lastRunFailed.insert(id) }
        save(library, for: scan)
    }

    // MARK: Hand tagging

    /// Adds a hand-tagged fixture at a photo spot. `spot` is where the photo was taken and `facing` the way it points
    /// on the plan; the fixture lands about 1.5 m out, pulled onto the nearest wall. With no walls it sits at the spot.
    @discardableResult
    func addManual(kind: Fixture.Kind, surface: Fixture.Surface, spot: PhotoSpot, plan: FloorPlan?,
                   ceilingHeight: Float?, scan: Scan, store: ScanStore) -> Fixture {
        self.store = store
        load(scan, store: store)
        let floorY = plan?.floorY ?? 0
        let target = FixturePlacement.manualPlan(spot: spot.position, facing: spot.facing, walls: plan?.walls ?? [])
        let ceilingY = floorY + (ceilingHeight ?? FixturePlacement.defaultCeilingHeight)
        let y = FixturePlacement.height(kind: kind, surface: surface,
                                        room: .init(floorY: floorY, ceilingY: ceilingY, walls: plan?.walls ?? []))
        let fixture = Fixture(kind: kind, surface: surface, position: SIMD3(target.point.x, y, target.point.y),
                              planPosition: target.point, length: nil,
                              axis: surface == .wall ? target.axis : nil,
                              photoFrame: spot.frameFile.isEmpty ? nil : spot.frameFile, photoBox: nil,
                              source: .manual, confidence: nil, confirmed: true)
        var library = libraries[scan.id] ?? FixtureLibrary()
        library.fixtures.append(fixture)
        save(library, for: scan)
        return fixture
    }

    /// Removes a fixture and returns it with its list position, so `restore` can put it back (undo).
    @discardableResult
    func delete(_ fixtureID: UUID, scan: Scan, store: ScanStore? = nil) -> (fixture: Fixture, index: Int)? {
        if let store { self.store = store }
        guard var library = libraries[scan.id], let index = library.fixtures.firstIndex(where: { $0.id == fixtureID })
        else { return nil }
        let removed = library.fixtures.remove(at: index)
        // A deleted detection stays deleted when the photos are checked again.
        if removed.source == .detected {
            library.dismissed = (library.dismissed ?? []) + [.init(kind: removed.kind, planPosition: removed.planPosition)]
        }
        save(library, for: scan)
        return (removed, index)
    }

    /// Puts a deleted fixture back where it was.
    func restore(_ fixture: Fixture, at index: Int, scan: Scan) {
        var library = libraries[scan.id] ?? FixtureLibrary()
        guard !library.fixtures.contains(where: { $0.id == fixture.id }) else { return }
        if let i = library.dismissed?.lastIndex(of: .init(kind: fixture.kind, planPosition: fixture.planPosition)) {
            library.dismissed?.remove(at: i)
        }
        library.fixtures.insert(fixture, at: min(index, library.fixtures.count))
        save(library, for: scan)
    }

    // MARK: Editing

    /// Adds a fixture at a point on the plan. Needs no photo. Wall kinds snap to the nearest wall.
    @discardableResult
    func add(kind: Fixture.Kind, surface: Fixture.Surface, at point: SIMD2<Float>, room: FixturePlacement.Room,
             scan: Scan) -> Fixture {
        let fixture = FixturePlacement.newFixture(kind: kind, surface: surface, at: point, room: room)
        var library = libraries[scan.id] ?? FixtureLibrary()
        library.fixtures.append(fixture)
        save(library, for: scan)
        return fixture
    }

    /// Applies a change to one fixture. The fixture counts as edited and checked from then on.
    func update(_ id: UUID, scan: Scan, _ change: (inout Fixture) -> Void) {
        guard var library = libraries[scan.id], let i = library.fixtures.firstIndex(where: { $0.id == id }) else { return }
        change(&library.fixtures[i])
        library.fixtures[i].edited = true
        library.fixtures[i].confirmed = true
        save(library, for: scan)
    }

    func setKind(_ kind: Fixture.Kind, surface: Fixture.Surface, for id: UUID, room: FixturePlacement.Room, scan: Scan) {
        update(id, scan: scan) { $0 = FixturePlacement.retargeted($0, kind: kind, surface: surface, room: room) }
    }

    /// Changes a heater's length, then re-snaps it so the longer bar still ends on its wall.
    func setLength(_ length: Float?, for id: UUID, room: FixturePlacement.Room, scan: Scan) {
        update(id, scan: scan) {
            $0.length = length
            $0 = FixturePlacement.moved($0, to: $0.planPosition, room: room)
        }
    }

    /// Moves a fixture to a plan point (wall kinds snap to a wall), keeping its height.
    func move(_ id: UUID, to point: SIMD2<Float>, room: FixturePlacement.Room, scan: Scan) {
        update(id, scan: scan) { $0 = FixturePlacement.moved($0, to: point, room: room) }
    }

    func confirm(_ id: UUID, scan: Scan) {
        guard var library = libraries[scan.id], let i = library.fixtures.firstIndex(where: { $0.id == id }),
              !library.fixtures[i].confirmed else { return }
        library.fixtures[i].confirmed = true
        save(library, for: scan)
    }

    /// Marks every unchecked detection as checked. Returns how many changed.
    @discardableResult
    func confirmAll(scan: Scan) -> Int {
        guard var library = libraries[scan.id] else { return 0 }
        var n = 0
        for i in library.fixtures.indices where library.fixtures[i].needsCheck {
            library.fixtures[i].confirmed = true
            n += 1
        }
        if n > 0 { save(library, for: scan) }
        return n
    }

    private func save(_ library: FixtureLibrary, for scan: Scan) {
        libraries[scan.id] = library
        guard let store else { return }
        library.write(to: store.fixturesURL(for: scan))   // a few KB: fine on the main actor
    }
}
