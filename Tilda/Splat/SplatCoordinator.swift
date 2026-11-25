import ARKit
import Foundation
import Metal
import Observation
import UIKit

// CONTRACT between the splat engine and the splat UI. The names and shapes below are fixed; the engine builder fills
// in the bodies marked TODO(engine). The UI builder codes against this file only.

/// Which phones can make splats. Training needs a Pro iPhone (LiDAR) with at least 8 GB of memory: iPhone 15 Pro and
/// later Pro models. Viewing a splat works on any device.
enum SplatSupport {
    /// True when this device can train splats.
    static var canTrain: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        // Decimal GB: an 8 GB iPhone reports a little under 8e9 bytes.
        MTLCreateSystemDefaultDevice() != nil
            && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ProcessInfo.processInfo.physicalMemory >= 7_500_000_000
        #endif
    }

    /// One plain sentence for the UI when `canTrain` is false, e.g. "Making a splat needs an iPhone 15 Pro or later."
    static var unavailableReason: String { "Making a splat needs an iPhone 15 Pro or later Pro model." }

    /// True when the scan has what training needs: saved photos with poses (`frames/transforms.json`) and at least
    /// `minimumPhotos` of them.
    static func hasInputs(scanFolder: URL) -> Bool {
        let framesDir = scanFolder.appendingPathComponent("frames", isDirectory: true)
        guard let manifest = FrameRecorder.load(from: framesDir) else { return false }
        var found = 0
        for frame in manifest.frames
        where FileManager.default.fileExists(atPath: framesDir.appendingPathComponent(frame.file_path).path) {
            found += 1
            if found >= minimumPhotos { return true }
        }
        return false
    }

    static let minimumPhotos = 20
}

/// How long the user is willing to wait.
enum SplatQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick, standard
    var id: String { rawValue }
    var title: String { self == .quick ? "Quick" : "Detailed" }
    var detail: String { self == .quick ? "Faster" : "Sharpest, takes about twice as long" }
}

/// Where training is for one scan. `progress` is 0...1.
enum SplatPhase: Equatable, Sendable {
    case idle
    /// Reading photos, checking sharpness, masking people, building the starting points.
    case preparing(step: String)
    case training(progress: Double, splatCount: Int, secondsLeft: Double?)
    case saving
    /// Finished this session; the splat is at `ScanStore.splatURL(for:)`.
    case finished
    /// The app left the foreground or another scan was started; training can resume from the checkpoint.
    case paused(progress: Double)
    case failed(message: String)
}

/// Owns splat training: one scan at a time, off the main thread, cancellable. Injected into the environment from
/// TildaApp like FixtureCoordinator.
@MainActor
@Observable
final class SplatCoordinator {
    /// Phase per scan. Missing means `.idle`.
    private(set) var phases: [UUID: SplatPhase] = [:]

    func phase(for id: UUID) -> SplatPhase { phases[id] ?? .idle }
    var isBusy: Bool {
        phases.values.contains { if case .preparing = $0 { return true }; if case .training = $0 { return true }
            if case .saving = $0 { return true }; return false }
    }

    private struct ActiveRun {
        let scanID: UUID
        let folder: URL
        let token: UUID
        let control: SplatControl
    }
    private struct PendingStart {
        let scan: Scan
        let store: ScanStore
        let quality: SplatQuality
    }

    /// The one run in flight (msplat allows a single Metal session at a time).
    @ObservationIgnored private var active: ActiveRun?
    /// A scan waiting for the active run to pause.
    @ObservationIgnored private var pending: PendingStart?
    @ObservationIgnored private weak var store: ScanStore?

    init() {
        let center = NotificationCenter.default
        // Leaving the foreground is a two-step: inactive first (Metal still allowed, so the worker saves a checkpoint and
        // holds), then background (the run ends). Coming back to active lets a held run carry on.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active?.control.setInactive(true) }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active?.control.setInactive(false) }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active?.control.request(.pause) }
        }
    }

    /// Starts (or resumes from a checkpoint) training for `scan`. Ignored when `SplatSupport.canTrain` is false or the
    /// scan has no inputs. Starting a second scan pauses the first.
    func start(_ scan: Scan, store: ScanStore, quality: SplatQuality) {
        guard SplatSupport.canTrain, SplatSupport.hasInputs(scanFolder: store.folderURL(for: scan)) else { return }
        self.store = store
        if let run = active {
            guard run.scanID != scan.id else { return }
            // Pause the running scan; this one starts as soon as it has let go of the GPU.
            if let old = pending, old.scan.id != scan.id { phases[old.scan.id] = nil }
            run.control.request(.pause)
            pending = PendingStart(scan: scan, store: store, quality: quality)
            phases[scan.id] = .preparing(step: "Waiting for the other splat to pause")
            return
        }
        begin(PendingStart(scan: scan, store: store, quality: quality))
    }

    /// Stops training and deletes the checkpoint. Keeps any finished splat.
    func cancel(_ id: UUID) {
        if pending?.scan.id == id { pending = nil; phases[id] = nil }
        if let run = active, run.scanID == id {
            run.control.request(.cancel)     // `finish` removes the checkpoint and clears the phase
            return
        }
        if let folder = folder(for: id) { SplatTrainer.deleteCheckpoint(folder) }
        phases[id] = nil
    }

    /// Deletes the scan's finished splat. A new splat being made for the same scan (running, waiting or paused, with
    /// its checkpoint) is left alone: deleting the old 3D photo must not throw away the new one.
    func deleteSplat(_ scan: Scan, store: ScanStore) {
        self.store = store
        try? FileManager.default.removeItem(at: SplatTrainer.splatURL(store.folderURL(for: scan)))
        if phases[scan.id] == .finished { phases[scan.id] = nil }
    }

    /// Call from the scene phase: `.background` pauses (saving a checkpoint), `.active` does nothing (the user resumes).
    func appMovedToBackground() {
        if let old = pending { pending = nil; phases[old.scan.id] = nil }
        active?.control.setInactive(true)
        active?.control.request(.pause)
    }

    /// Call when `store.scans` changes: forgets scans that were deleted (their folder is gone) and stops their run.
    func sync(store: ScanStore) {
        self.store = store
        let ids = Set(store.scans.map(\.id))
        for id in Array(phases.keys) where !ids.contains(id) {
            if active?.scanID == id { active?.control.request(.cancel) }
            if pending?.scan.id == id { pending = nil }
            phases[id] = nil
        }
    }

    // MARK: Running

    private func folder(for id: UUID) -> URL? {
        guard let store, let scan = store.scans.first(where: { $0.id == id }) else { return nil }
        return store.folderURL(for: scan)
    }

    private func begin(_ job: PendingStart) {
        let id = job.scan.id
        let folder = job.store.folderURL(for: job.scan)
        let modelURL = job.store.modelURL(for: job.scan)
        let control = SplatControl()
        control.setInactive(UIApplication.shared.applicationState != .active)
        let token = UUID()
        active = ActiveRun(scanID: id, folder: folder, token: token, control: control)
        phases[id] = .preparing(step: "Reading photos")
        UIApplication.shared.isIdleTimerDisabled = true      // a long run must not be cut off by auto-lock

        // Progress goes through the main queue (in order) and is dropped once this run has finished.
        let publish: @Sendable (SplatPhase) -> Void = { [weak self] phase in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(phase, token: token) } }
        }
        let quality = job.quality
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<SplatTrainer.Outcome, Error>
            do {
                result = .success(try await SplatTrainer.run(scanFolder: folder, modelURL: modelURL, quality: quality,
                                                             control: control, publish: publish))
            } catch {
                result = .failure(error)
            }
            await self?.finish(token: token, result: result)
        }
    }

    private func apply(_ phase: SplatPhase, token: UUID) {
        guard let run = active, run.token == token else { return }
        phases[run.scanID] = phase
    }

    private func finish(token: UUID, result: Result<SplatTrainer.Outcome, Error>) {
        guard let run = active, run.token == token else { return }
        active = nil
        UIApplication.shared.isIdleTimerDisabled = false
        switch result {
        case .success(.finished):
            phases[run.scanID] = .finished
        case .success(.paused(let progress)):
            phases[run.scanID] = .paused(progress: progress)
        case .success(.cancelled):
            SplatTrainer.deleteCheckpoint(run.folder)
            phases[run.scanID] = nil
        case .failure(let error):
            NSLog("Splat training failed: %@", String(describing: error))
            phases[run.scanID] = .failed(message: SplatTrainer.message(for: error))
        }
        // The scan folder is gone (scan deleted while training): nothing to show.
        if !FileManager.default.fileExists(atPath: run.folder.path) { phases[run.scanID] = nil }
        if let next = pending {
            pending = nil
            begin(next)
        }
    }
}

extension ScanStore {
    /// The finished splat (`splat.ply` in the scan folder), if any.
    func splatURL(for scan: Scan) -> URL? {
        let url = folderURL(for: scan).appendingPathComponent("splat.ply")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
