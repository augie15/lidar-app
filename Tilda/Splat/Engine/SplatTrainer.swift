import Foundation
import Msplat
import os

/// Lets the coordinator (main thread) steer a training run that lives on a background task.
final class SplatControl: @unchecked Sendable {
    enum Stop: Sendable { case none, pause, cancel }

    private let lock = NSLock()
    private var _stop: Stop = .none
    private var _inactive = false

    var stop: Stop { lock.withLock { _stop } }
    var isInactive: Bool { lock.withLock { _inactive } }

    /// Cancel beats pause: once cancelled, a later pause request cannot undo it.
    func request(_ stop: Stop) {
        lock.withLock { if _stop != .cancel { _stop = stop } }
    }

    /// The app is inactive (notification shade, app switcher, about to background): no new Metal work until active.
    func setInactive(_ inactive: Bool) { lock.withLock { _inactive = inactive } }

    /// Blocks the calling worker thread while the app is inactive (and nothing asked it to stop).
    func waitWhileInactive() {
        while isInactive && stop == .none { usleep(50_000) }
    }
}

/// Small note next to a checkpoint: which quality it belongs to and how far it got.
struct SplatCheckpointInfo: Codable, Sendable {
    var quality: SplatQuality
    var iteration: Int
    var totalIterations: Int
}

/// Runs one training: prepares the photos, opens the msplat session, steps it, checkpoints, exports `splat.ply`.
/// Everything here runs off the main thread (the msplat session itself lives on its own runtime actor).
enum SplatTrainer {
    enum Outcome: Sendable { case finished, paused(progress: Double), tooHot(progress: Double), cancelled }

    /// What the step loop does at each iOS thermal state. Training runs the GPU flat out, so it backs off before iOS
    /// throttles the whole phone (serious) and stops outright at critical, when iOS may end the app.
    enum ThermalAction: Equatable { case run, cool, stop }
    static func thermalAction(_ state: ProcessInfo.ThermalState) -> ThermalAction {
        switch state {
        case .nominal, .fair: .run
        case .serious: .cool
        case .critical: .stop
        @unknown default: .run
        }
    }

    // MARK: Files

    static func checkpointURL(_ folder: URL) -> URL { folder.appendingPathComponent("splat-checkpoint.msplat") }
    static func checkpointInfoURL(_ folder: URL) -> URL { folder.appendingPathComponent("splat-checkpoint.json") }
    static func splatURL(_ folder: URL) -> URL { folder.appendingPathComponent("splat.ply") }

    static func readInfo(_ folder: URL) -> SplatCheckpointInfo? {
        guard FileManager.default.fileExists(atPath: checkpointURL(folder).path),
              let data = try? Data(contentsOf: checkpointInfoURL(folder)) else { return nil }
        return try? JSONDecoder().decode(SplatCheckpointInfo.self, from: data)
    }

    static func deleteCheckpoint(_ folder: URL) {
        try? FileManager.default.removeItem(at: checkpointURL(folder))
        try? FileManager.default.removeItem(at: checkpointInfoURL(folder))
    }

    // MARK: Settings

    struct Settings: Equatable {
        var iterations: Int
        var shDegree: Int32
        /// Longest photo edge fed to the trainer.
        var longestEdge: Int
        var maxGaussians: Int
        /// Share of the iterations trained at half resolution first (cheap, lays down the coarse shape).
        var coarseFraction: Double
    }

    /// First phone run (iPhone 17 Pro, Quick at 3000 steps / 960 px / SH 2) came out soft: 320k splats with a median
    /// size of 2.5 cm across a living room and kitchen. Sharp room splats need 1M+ splats, many under 1 cm, trained on
    /// near-full-size photos for longer. So: more steps, bigger photos, SH 3 (view-dependent shine), splats keep
    /// multiplying until 60% of the run, and higher caps. The memory check in `makePlan` still trims all of this to
    /// what the phone can hold.
    static func settings(for quality: SplatQuality, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Settings {
        let big = physicalMemory >= 11_000_000_000
        switch quality {
        case .quick:
            return Settings(iterations: 7_000, shDegree: 3, longestEdge: 1_440, maxGaussians: big ? 1_000_000 : 600_000,
                            coarseFraction: 0.3)
        case .standard:
            return Settings(iterations: 15_000, shDegree: 3, longestEdge: 1_920, maxGaussians: big ? 1_800_000 : 900_000,
                            coarseFraction: 0.2)
        }
    }

    /// Splats stop splitting and cloning after this share of the run, then the rest sharpens what is there.
    static let densifyUntil = 0.6

    /// Builds the plan and checks its estimated peak memory against what iOS will still give this app. If it does not
    /// fit, trims the Gaussian cap and the photo size in turns and tries again.
    static func makePlan(dataset: SplatDataset, settings: Settings, availableBytes: Int64) throws -> TrainingPlan {
        let initial = dataset.descriptor.points.count
        let dims = try TrainingImageDimensions(width: dataset.width, height: dataset.height)
        let longest = max(dataset.width, dataset.height)
        let budget = Int32(settings.iterations)
        let coarseEnd = max(1, Int32(Double(budget) * settings.coarseFraction))
        let stages = [try TrainingResolutionStage(iterations: 1...coarseEnd, downscaleFactor: 2),
                      try TrainingResolutionStage(iterations: (coarseEnd + 1)...budget, downscaleFactor: 1)]
        var edge = settings.longestEdge
        var maxGaussians = max(settings.maxGaussians, initial + initial / 4)
        let floorGaussians = max(120_000, initial + initial / 4), floorEdge = 480
        var trimCap = true
        while true {
            let plan = try TrainingPlan(inputDimensions: dims,
                                        inputDecodeScale: min(32, max(1, Float(longest) / Float(edge))),
                                        iterationBudget: budget, stages: stages, targetSHDegree: settings.shDegree,
                                        maximumGaussianCount: maxGaussians, includesTrainingMasks: dataset.hasMasks,
                                        appearanceMode: .rgbGains)
            // Zero means the system did not say (Simulator); trust the plan then.
            if availableBytes <= 0 || plan.estimatedPeakMemory <= Int64(Double(availableBytes) * 0.85) { return plan }
            let canTrimCap = maxGaussians > floorGaussians, canTrimEdge = edge > floorEdge
            guard canTrimCap || canTrimEdge else {
                throw SplatFailure(message: "There is not enough free memory to make this splat. Close other apps and try again.")
            }
            if (trimCap && canTrimCap) || !canTrimEdge { maxGaussians = max(floorGaussians, maxGaussians * 3 / 4) }
            else { edge = max(floorEdge, edge * 85 / 100) }
            trimCap.toggle()
        }
    }

    // MARK: Run

    /// Trains `scanFolder`'s scan. Publishes phases through `publish` (the caller throttles nothing: progress is
    /// already limited to ~4 per second here). Returns when finished, paused (checkpoint saved) or cancelled.
    static func run(scanFolder: URL, modelURL: URL, quality: SplatQuality, control: SplatControl,
                    publish: @escaping @Sendable (SplatPhase) -> Void) async throws -> Outcome {
        let fm = FileManager.default
        let maskDirectory = fm.temporaryDirectory.appendingPathComponent("splat-masks-" + scanFolder.lastPathComponent, isDirectory: true)
        defer { try? fm.removeItem(at: maskDirectory) }

        // A checkpoint only fits the quality it was made for (the training plan differs).
        var resumeInfo = readInfo(scanFolder)
        if let info = resumeInfo, info.quality != quality { deleteCheckpoint(scanFolder); resumeInfo = nil }
        func outcomeForStop(_ progress: Double) -> Outcome { control.stop == .cancel ? .cancelled : .paused(progress: progress) }
        let resumeProgress = resumeInfo.map { Double($0.iteration) / Double(max(1, $0.totalIterations)) } ?? 0

        // Photos, people, starting points.
        publish(.preparing(step: "Reading photos"))
        let dataset: SplatDataset
        do {
            dataset = try SplatDatasetBuilder.build(
                scanFolder: scanFolder, modelURL: modelURL, maskDirectory: maskDirectory,
                report: { publish(.preparing(step: $0)) },
                shouldStop: { control.waitWhileInactive(); return control.stop != .none })
        } catch is SplatInterrupted {
            return outcomeForStop(resumeProgress)
        }

        let settings = settings(for: quality)
        let available = Int64(os_proc_available_memory())
        let plan = try makePlan(dataset: dataset, settings: settings, availableBytes: available)
        var config = TrainingConfig()
        config.keepCrs = true                       // export in ARKit world space so the splat lines up with the scan
        config.trainingMaskMode = .coverage         // masked pixels (people) simply do not count
        config.bgColor = (0.02, 0.02, 0.02)
        // ARKit poses drift by millimetres and auto-exposure changes between photos; both smear detail. Let msplat learn
        // small per-photo pose corrections and colour gains (training only; the exported splat stays in ARKit space).
        config.refineCameraPoses = true
        config.densifyGradThresh = 0.00015           // grow a little more readily than the 30k-step default
        config.stopDensifyAt = Int32(Double(plan.iterationBudget) * densifyUntil)
        config = try plan.makeTrainingConfig(startingFrom: config)
        // Short runs with many photos can leave no growth steps; fall back to training the seed points as they are.
        if let schedule = try? config.densificationSchedule(trainingCameraCount: dataset.descriptor.frames.count),
           schedule.isEnabled, schedule.eventCount == 0 {
            config.stopDensifyAt = 0
        }
        if control.stop != .none { return outcomeForStop(resumeProgress) }
        control.waitWhileInactive()

        publish(.preparing(step: "Starting the trainer"))
        let total = Int(plan.iterationBudget)
        func openSession() async throws -> MsplatSession {
            try await MsplatSession(dataset: dataset.descriptor,
                                    options: try plan.makeDatasetOptions(prefetchTrainingTargets: true),
                                    config: config, maximumGaussianCount: plan.maximumGaussianCount)
        }
        var session = try await openSession()
        var iteration = 0
        if resumeInfo != nil {
            do { iteration = try await session.loadCheckpoint(from: checkpointURL(scanFolder)) }
            catch {
                // The checkpoint does not fit this dataset any more (photos or settings changed): start over.
                try? await session.close()
                deleteCheckpoint(scanFolder)
                session = try await openSession()
                iteration = 0
            }
        }
        let live = session

        do {
            // MARK: Step loop
            var lastCheckpoint = iteration
            func checkpoint() async throws {
                msplatSync()
                let tmp = scanFolder.appendingPathComponent("splat-checkpoint.tmp.msplat")
                do { try await live.saveCheckpoint(to: tmp) }
                catch { try? fm.removeItem(at: tmp); throw error }
                let dest = checkpointURL(scanFolder)
                if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
                else { try fm.moveItem(at: tmp, to: dest) }
                // Resumable scratch (hundreds of MB): keep it out of iCloud and computer backups.
                var noBackup = URLResourceValues()
                noBackup.isExcludedFromBackup = true
                var destURL = dest
                try? destURL.setResourceValues(noBackup)
                let info = SplatCheckpointInfo(quality: quality, iteration: iteration, totalIterations: total)
                try JSONEncoder().encode(info).write(to: checkpointInfoURL(scanFolder), options: .atomic)
                lastCheckpoint = iteration
            }

            var splatCount = (try? await live.splatCount) ?? dataset.descriptor.points.count
            var lastPublish = Date.distantPast
            var windowStart = Date(), windowIteration = iteration
            var smoothedRate: Double?
            publish(.training(progress: Double(iteration) / Double(total), splatCount: splatCount, secondsLeft: nil))

            // One save attempt per inactive spell: if the app is already past inactive, the GPU refuses it, and
            // retrying every tick would only fail again.
            var triedInactiveSave = false
            while iteration < total, control.stop == .none {
                if control.isInactive {
                    // Metal work is not allowed once the app is going to the background: save now, then wait.
                    if lastCheckpoint != iteration && !triedInactiveSave {
                        triedInactiveSave = true
                        do { try await checkpoint() }
                        catch { NSLog("Splat checkpoint while inactive failed: %@", String(describing: error)) }
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    windowStart = Date(); windowIteration = iteration
                    continue
                }
                triedInactiveSave = false
                // Heat: hold (no GPU work) until the phone cools, or stop at critical. A checkpoint first either way.
                switch thermalAction(ProcessInfo.processInfo.thermalState) {
                case .run: break
                case .stop:
                    if lastCheckpoint != iteration { try await checkpoint() }
                    try? await live.close()
                    return .tooHot(progress: Double(iteration) / Double(total))
                case .cool:
                    if lastCheckpoint != iteration { try await checkpoint() }
                    publish(.cooling(progress: Double(iteration) / Double(total)))
                    while thermalAction(ProcessInfo.processInfo.thermalState) == .cool, control.stop == .none {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    windowStart = Date(); windowIteration = iteration; smoothedRate = nil
                    lastPublish = .distantPast
                    continue          // re-check: cooled (run), hotter (stop) or asked to stop
                }
                let stats = try await live.step()
                iteration += 1
                splatCount = stats.splatCount

                if iteration - lastCheckpoint >= 500 && iteration < total { try await checkpoint() }

                let now = Date()
                let elapsed = now.timeIntervalSince(lastPublish)
                if elapsed >= 0.25 || iteration == total {
                    lastPublish = now
                    let span = now.timeIntervalSince(windowStart)
                    if span >= 0.5 {
                        // Recent speed, smoothed: the first half runs at half resolution and is faster than the rest.
                        let rate = Double(iteration - windowIteration) / span
                        smoothedRate = smoothedRate.map { $0 * 0.7 + rate * 0.3 } ?? rate
                        windowStart = now; windowIteration = iteration
                    }
                    let left: Double? = smoothedRate.flatMap { $0 > 0 && iteration >= 30 ? Double(total - iteration) / $0 : nil }
                    publish(.training(progress: Double(iteration) / Double(total), splatCount: splatCount, secondsLeft: left))
                }
            }

            if control.stop == .cancel { try? await live.close(); return .cancelled }
            if control.stop == .pause {
                // Save only while the app is still active (another scan started, memory warning). In the background,
                // or on the way there, the GPU refuses the work: keep the last checkpoint instead of failing the run.
                if lastCheckpoint != iteration && !control.isInactive {
                    do { try await checkpoint() }
                    catch { NSLog("Splat checkpoint on pause failed: %@", String(describing: error)) }
                }
                try? await live.close()
                // Resume starts from the last saved checkpoint, so report that, not the iteration reached.
                return .paused(progress: Double(lastCheckpoint) / Double(total))
            }

            // MARK: Export
            publish(.saving)
            msplatSync()
            let tmp = scanFolder.appendingPathComponent("splat-export.tmp.ply")
            try? fm.removeItem(at: tmp)
            try await live.exportPLY(to: tmp)
            guard fm.fileExists(atPath: tmp.path) else {
                throw SplatFailure(message: "The splat could not be saved. Check that the phone has free space.")
            }
            let dest = splatURL(scanFolder)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dest) }
            deleteCheckpoint(scanFolder)
            try? await live.close()
            return .finished
        } catch {
            try? await live.close()
            try? fm.removeItem(at: scanFolder.appendingPathComponent("splat-export.tmp.ply"))
            try? fm.removeItem(at: scanFolder.appendingPathComponent("splat-checkpoint.tmp.msplat"))
            throw error
        }
    }

    /// A plain sentence for whatever went wrong.
    static func message(for error: Error) -> String {
        if let failure = error as? SplatFailure { return failure.message }
        if let m = error as? MsplatError {
            switch m {
            case .outOfMemory:
                return "The phone ran out of memory. Close other apps and try again, or pick Quick."
            case .ioFailure:
                return "The splat could not be saved. Check that the phone has free space."
            case .gpuFailure:
                return "The phone's graphics chip stopped the job. Keep Tilda open and try again."
            case .invalidDataset:
                return "This scan's photos could not be used to make a splat."
            default: break
            }
        }
        return "Making the splat stopped unexpectedly. Try again."
    }
}
