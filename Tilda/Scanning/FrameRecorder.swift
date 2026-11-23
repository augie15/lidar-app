import ARKit
import CoreImage
import Foundation
import simd

/// Records ARKit keyframes (JPEG + camera pose + intrinsics) while a scan runs.
///
/// Output folder layout (Nerfstudio-compatible, readable by most Gaussian-splat tools):
///   frames/
///     images/frame_00001.jpg ...   ← sensor orientation (landscape). Rotate 90° clockwise to show portrait.
///     transforms.json
///
/// `transforms.json` holds top-level intrinsics plus per-frame `transform_matrix` (camera-to-world, ARKit world
/// space: metres, +Y up, camera looks down -Z, i.e. the OpenGL convention Nerfstudio expects) and per-frame
/// intrinsics `fl_x fl_y cx cy w h`. Read it back with `FrameRecorder.load(from:)`.
///
/// Thread-safe: call `consider(_:)` from any thread (ARSession delegate or a timer polling `currentFrame`).
final class FrameRecorder: @unchecked Sendable {
    struct Frame: Codable, Sendable {
        var file_path: String
        var transform_matrix: [[Float]]
        var fl_x: Float
        var fl_y: Float
        var cx: Float
        var cy: Float
        var w: Int
        var h: Int
        var timestamp: Double

        /// Camera-to-world transform as a simd matrix.
        var transform: simd_float4x4 {
            let r = transform_matrix
            return simd_float4x4(columns: (
                SIMD4(r[0][0], r[1][0], r[2][0], r[3][0]),
                SIMD4(r[0][1], r[1][1], r[2][1], r[3][1]),
                SIMD4(r[0][2], r[1][2], r[2][2], r[3][2]),
                SIMD4(r[0][3], r[1][3], r[2][3], r[3][3])))
        }
        var position: SIMD3<Float> { let c = transform.columns.3; return SIMD3(c.x, c.y, c.z) }
    }

    struct Manifest: Codable, Sendable {
        var camera_model = "OPENCV"
        var fl_x: Float
        var fl_y: Float
        var cx: Float
        var cy: Float
        var w: Int
        var h: Int
        var frames: [Frame]
    }

    /// The `frames/` folder. Pass it to `ScanStore.importModel(... attachments:)` after `finish()`.
    let directory: URL
    private let imagesDir: URL
    private let queue = DispatchQueue(label: "Tilda.FrameRecorder", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()

    private var frames: [Frame] = []
    private var lastKept: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var inFlight = false
    private var isFinished = false

    private let minTranslation: Float
    private let minRotation: Float
    private let maxFrames: Int
    private let minInterval: TimeInterval = 0.35

    init(density: AppSettings.PhotoDensity = AppSettings.photoDensity) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = root.appendingPathComponent("frames", isDirectory: true)
        imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let t = density.thresholds
        minTranslation = t.translation
        minRotation = t.rotationDegrees * .pi / 180
        maxFrames = t.maxFrames
    }

    var frameCount: Int { lock.withLock { frames.count } }

    /// Keeps the frame if tracking is good and the camera has moved or turned enough since the last keyframe.
    func consider(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let transform = frame.camera.transform
        let time = frame.timestamp

        let shouldKeep: Bool = lock.withLock {
            guard !isFinished, !inFlight, frames.count < maxFrames, time - lastTime >= minInterval else { return false }
            if let last = lastKept {
                let moved = simd_distance(last.columns.3, transform.columns.3)
                let fwdA = -SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z)
                let fwdB = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                let turned = acos(min(max(simd_dot(simd_normalize(fwdA), simd_normalize(fwdB)), -1), 1))
                guard moved >= minTranslation || turned >= minRotation else { return false }
            }
            inFlight = true
            lastKept = transform
            lastTime = time
            return true
        }
        guard shouldKeep else { return }

        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let image = CIImage(cvPixelBuffer: frame.capturedImage)   // only the CIImage is retained, not the ARFrame
        let index = lock.withLock { frames.count + 1 }
        let name = String(format: "frame_%05d.jpg", index)
        let rows: [[Float]] = (0..<4).map { r in (0..<4).map { c in transform[c][r] } }

        queue.async { [self] in
            defer { lock.withLock { inFlight = false } }
            let url = imagesDir.appendingPathComponent(name)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = ciContext.jpegRepresentation(of: image, colorSpace: space,
                                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]),
                  (try? data.write(to: url)) != nil else { return }
            let record = Frame(file_path: "images/\(name)", transform_matrix: rows,
                               fl_x: k[0][0], fl_y: k[1][1], cx: k[2][0], cy: k[2][1],
                               w: Int(size.width), h: Int(size.height), timestamp: time)
            lock.withLock { frames.append(record) }
        }
    }

    /// Stops recording, writes transforms.json, and returns the `frames/` folder (nil if nothing was kept).
    /// Blocking: call off the main thread.
    func finish() -> URL? {
        lock.withLock { isFinished = true }
        queue.sync {}
        let kept = lock.withLock { frames }
        guard let first = kept.first else {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
            return nil
        }
        let manifest = Manifest(fl_x: first.fl_x, fl_y: first.fl_y, cx: first.cx, cy: first.cy,
                                w: first.w, h: first.h, frames: kept)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest),
              (try? data.write(to: directory.appendingPathComponent("transforms.json"))) != nil else { return nil }
        return directory
    }

    /// Discards everything recorded so far.
    func cancel() {
        lock.withLock { isFinished = true }
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    }

    /// Reads a saved `frames/` folder.
    static func load(from framesDir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: framesDir.appendingPathComponent("transforms.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
