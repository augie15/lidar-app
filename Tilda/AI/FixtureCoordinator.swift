import Foundation
import Observation
import simd

/// Owns every scan's fixtures: loads and saves `fixtures.json`, runs photo detection in the background (one scan at a
/// time, cancellable, never on the main thread), and applies hand-tagged additions and deletions.
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

    /// "Find fixtures" / "Scan photos again". Hand-tagged fixtures are kept; earlier detections are replaced.
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
        library.fixtures = library.fixtures.filter { $0.source == .manual } + output.fixtures
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
        let y: Float = switch surface {
        case .floor: floorY
        case .ceiling: ceilingY
        case .wall: kind == .baseboardHeater ? floorY + 0.15 : floorY + 0.3
        }
        let fixture = Fixture(kind: kind, surface: surface, position: SIMD3(target.point.x, y, target.point.y),
                              planPosition: target.point, length: nil,
                              axis: kind == .baseboardHeater ? target.axis : nil,
                              photoFrame: spot.frameFile.isEmpty ? nil : spot.frameFile, photoBox: nil,
                              source: .manual, confidence: nil)
        var library = libraries[scan.id] ?? FixtureLibrary()
        library.fixtures.append(fixture)
        save(library, for: scan)
        return fixture
    }

    func delete(_ fixtureID: UUID, scan: Scan, store: ScanStore) {
        self.store = store
        guard var library = libraries[scan.id] else { return }
        library.fixtures.removeAll { $0.id == fixtureID }
        save(library, for: scan)
    }

    private func save(_ library: FixtureLibrary, for scan: Scan) {
        libraries[scan.id] = library
        guard let store else { return }
        library.write(to: store.fixturesURL(for: scan))   // a few KB: fine on the main actor
    }
}
