import Foundation
import ImageIO
import Msplat
import simd

/// A problem to show the user, already in plain words.
struct SplatFailure: Error, Sendable {
    var message: String
}

/// Thrown from the builder and trainer when the run was paused or cancelled; never shown.
struct SplatInterrupted: Error {}

/// What the trainer needs, built from a saved scan.
struct SplatDataset: @unchecked Sendable {
    var descriptor: DatasetDescriptor
    /// Folder holding the person masks (delete it when training is over), nil when no mask was written.
    var maskDirectory: URL?
    var hasMasks: Bool
    var photoCount: Int
    var maskCount: Int
    /// Largest photo, used to size the training plan.
    var width: Int
    var height: Int
}

/// Turns `frames/transforms.json` + photos + the scan's geometry into an msplat `DatasetDescriptor`.
enum SplatDatasetBuilder {
    /// Share of the blurriest photos to leave out.
    static let blurDropFraction: Float = 0.15
    /// More photos than this only cost time and memory; the sharpest are spread evenly across the walk.
    static let maxPhotos = 500

    /// `report` gets the step names shown to the user; `shouldStop` is polled between photos.
    static func build(scanFolder: URL, modelURL: URL, maskDirectory: URL,
                      report: (String) -> Void, shouldStop: () -> Bool) throws -> SplatDataset {
        let framesDir = scanFolder.appendingPathComponent("frames", isDirectory: true)
        guard let manifest = FrameRecorder.load(from: framesDir) else {
            throw SplatFailure(message: "This scan's photos could not be read.")
        }
        // Photos that exist, with their real size (scale the intrinsics if it differs from the manifest).
        struct Candidate { var frame: FrameRecorder.Frame; var url: URL; var size: (width: Int, height: Int) }
        var candidates: [Candidate] = []
        for frame in manifest.frames {
            let url = framesDir.appendingPathComponent(frame.file_path)
            guard FileManager.default.fileExists(atPath: url.path), let size = SplatPhotoPrep.pixelSize(of: url),
                  frame.fl_x > 0, frame.fl_y > 0 else { continue }
            candidates.append(Candidate(frame: frame, url: url, size: size))
        }
        guard candidates.count >= SplatSupport.minimumPhotos else {
            throw SplatFailure(message: "This scan has too few photos to make a splat.")
        }

        // 1. Sharpness: drop the blurriest photos (but keep enough to cover the scene).
        report("Checking photo sharpness")
        var scores = [Float](repeating: -1, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            guard !shouldStop() else { return }
            let s = SplatPhotoPrep.sharpness(of: candidates[i].url) ?? 0
            lock.withLock { scores[i] = s }
        }
        if shouldStop() { throw SplatInterrupted() }
        var keep = SplatMath.keepIndices(scores: scores, dropFraction: blurDropFraction, minimum: SplatSupport.minimumPhotos)
        if keep.count > maxPhotos { keep = SplatMath.evenIndices(count: keep.count, limit: maxPhotos).map { keep[$0] } }
        let chosen = keep.map { candidates[$0] }

        // 2. People: a mask for every photo with someone in it.
        report("Removing people")
        try? FileManager.default.removeItem(at: maskDirectory)
        try FileManager.default.createDirectory(at: maskDirectory, withIntermediateDirectories: true)
        var maskURLs = [URL?](repeating: nil, count: chosen.count)
        DispatchQueue.concurrentPerform(iterations: chosen.count) { i in
            guard !shouldStop() else { return }
            let c = chosen[i]
            let name = (c.frame.file_path as NSString).lastPathComponent as NSString
            let maskURL = maskDirectory.appendingPathComponent(name.deletingPathExtension + "-mask.png")
            let orientation = SplatMath.uprightOrientation(cameraToWorld: c.frame.transform)
            if SplatPhotoPrep.writePersonMask(for: c.url, size: c.size, orientation: orientation, to: maskURL) {
                lock.withLock { maskURLs[i] = maskURL }
            }
        }
        if shouldStop() { throw SplatInterrupted() }

        // 3. Starting points.
        report("Building starting points")
        let keyframes = chosen.map { c in
            ColorKeyframe(imageURL: c.url, cameraToWorld: c.frame.transform,
                          fx: c.frame.fl_x * Float(c.size.width) / Float(max(1, c.frame.w)),
                          fy: c.frame.fl_y * Float(c.size.height) / Float(max(1, c.frame.h)),
                          cx: c.frame.cx * Float(c.size.width) / Float(max(1, c.frame.w)),
                          cy: c.frame.cy * Float(c.size.height) / Float(max(1, c.frame.h)),
                          width: c.size.width, height: c.size.height)
        }
        guard let seeds = SplatSeedPoints.build(modelURL: modelURL, keyframes: keyframes), seeds.count > 0 else {
            throw SplatFailure(message: "This scan has no shape to start from.")
        }
        if shouldStop() { throw SplatInterrupted() }

        // 4. The descriptor. Per-frame pinhole calibration, no distortion (ARKit's images are already corrected).
        var frames: [DatasetFrame] = []
        frames.reserveCapacity(chosen.count)
        do {
            for (i, c) in chosen.enumerated() {
                let k = keyframes[i]
                let id = ((c.frame.file_path as NSString).lastPathComponent as NSString).deletingPathExtension
                let calibration = try DatasetCalibration(width: c.size.width, height: c.size.height,
                                                         fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy)
                let mask = try maskURLs[i].map { try DatasetTrainingMask(url: $0, coverageChannel: .luminance) }
                frames.append(try DatasetFrame(id: id, calibrationID: "cal-" + id, imageURL: c.url,
                                               rasterOrientation: .encodedPixels, calibration: calibration,
                                               cameraToWorld: CameraPose(elements: SplatMath.msplatPose(fromARKit: c.frame.transform)),
                                               trainingMask: mask))
            }
            let points = try DatasetSparsePointSet(xyz: seeds.xyz, rgb: seeds.rgb)
            let descriptor = try DatasetDescriptor(frames: frames, points: points,
                                                   provenance: try DatasetProvenance(adapter: "Tilda", source: "ARKit keyframes"))
            let maskCount = maskURLs.compactMap { $0 }.count
            return SplatDataset(descriptor: descriptor, maskDirectory: maskDirectory, hasMasks: maskCount > 0,
                                photoCount: chosen.count, maskCount: maskCount,
                                width: chosen.map(\.size.width).max() ?? 0, height: chosen.map(\.size.height).max() ?? 0)
        } catch let failure as SplatFailure {
            throw failure
        } catch {
            throw SplatFailure(message: "The photos could not be prepared for training.")
        }
    }
}
