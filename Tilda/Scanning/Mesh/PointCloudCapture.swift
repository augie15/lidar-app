import ARKit
import CoreVideo
import SceneKit
import simd

/// Live point cloud from the LiDAR depth map.
///
/// `consider(_:)` is called for every ARFrame on the session's delegate queue and only does a throttle check plus a few
/// retains. The unprojection, voxel dedupe and geometry building run on one serial background queue, one frame at a
/// time (frames that arrive while it is busy are dropped). The main thread only attaches finished SceneKit nodes.
///
/// Display strategy: points are appended to the screen in insertion order. Every `displayChunk` points a chunk becomes
/// an immutable `SCNGeometry` (never touched again); only the small tail chunk is rebuilt per update. Merging a later
/// sample into an existing voxel refines the saved cloud (used for the PLY) but not the on-screen copy.
final class PointCloudCapture: @unchecked Sendable {
    struct Options: Sendable {
        var minConfidence: UInt8
        var maxRange: Float
        var cellSize: Float
        var removePeople: Bool
        var smooth: Bool
    }

    struct Update: @unchecked Sendable {
        var frozen: [SCNGeometry]
        var tail: SCNGeometry?
        var count: Int
        var capped: Bool
    }

    static let maxPoints = 4_000_000
    static let displayChunk = 50_000
    static let minInterval: TimeInterval = 0.12   // about 8 Hz

    private let options: Options
    private let onUpdate: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "Tilda.PointCloud", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = false
    private var finished = false
    private var lastTime: TimeInterval = -1

    // Touched only on `queue`.
    private let cloud: VoxelCloud
    private var tailPositions: [Float] = []
    private var tailColors: [UInt8] = []

    init(options: Options, onUpdate: @escaping @Sendable (Update) -> Void) {
        self.options = options
        self.onUpdate = onUpdate
        cloud = VoxelCloud(cellSize: options.cellSize, maxPoints: Self.maxPoints)
    }

    private struct Job: @unchecked Sendable {
        var depth: CVPixelBuffer
        var confidence: CVPixelBuffer?
        var image: CVPixelBuffer
        var segmentation: CVPixelBuffer?
        var cameraToWorld: simd_float4x4
        var intrinsics: simd_float3x3
        var imageSize: CGSize
    }

    /// Cheap: safe to call from the ARSession delegate for every frame.
    func consider(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        let go: Bool = lock.withLock {
            guard !finished, !inFlight, t - lastTime >= Self.minInterval else { return false }
            inFlight = true
            lastTime = t
            return true
        }
        guard go else { return }
        let depthData = options.smooth
            ? (frame.smoothedSceneDepth ?? frame.sceneDepth)
            : (frame.sceneDepth ?? frame.smoothedSceneDepth)
        guard let depthData else {
            lock.withLock { inFlight = false }
            return
        }
        let job = Job(depth: depthData.depthMap, confidence: depthData.confidenceMap, image: frame.capturedImage,
                      segmentation: options.removePeople ? frame.segmentationBuffer : nil,
                      cameraToWorld: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                      imageSize: frame.camera.imageResolution)
        queue.async { [self] in
            process(job)
            lock.withLock { inFlight = false }
        }
    }

    /// Stops accepting frames and returns the deduped cloud for export. Blocking: call off the main thread when the
    /// cloud is large (it is only a queue hop).
    func finish() -> VoxelCloud {
        lock.withLock { finished = true }
        return queue.sync { cloud }
    }

    // MARK: Processing (on `queue`)

    private func process(_ job: Job) {
        let depth = job.depth
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(job.image, .readOnly)
        if let c = job.confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        if let s = job.segmentation { CVPixelBufferLockBaseAddress(s, .readOnly) }
        defer {
            if let s = job.segmentation { CVPixelBufferUnlockBaseAddress(s, .readOnly) }
            if let c = job.confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
            CVPixelBufferUnlockBaseAddress(job.image, .readOnly)
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPlaneCount(job.image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(job.image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(job.image, 1) else { return }

        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let depthRow = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float>.size
        let k = DepthUnprojection.scaledIntrinsics(job.intrinsics, imageWidth: Float(job.imageSize.width),
                                                   imageHeight: Float(job.imageSize.height),
                                                   depthWidth: dw, depthHeight: dh)

        // Captured image planes (biplanar YCbCr 4:2:0, sensor orientation, same field of view as the depth map).
        let iw = CVPixelBufferGetWidthOfPlane(job.image, 0), ih = CVPixelBufferGetHeightOfPlane(job.image, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(job.image, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(job.image, 1)
        let cw = CVPixelBufferGetWidthOfPlane(job.image, 1), ch = CVPixelBufferGetHeightOfPlane(job.image, 1)
        let sx = Float(iw) / Float(dw), sy = Float(ih) / Float(dh)
        let cx = Float(cw) / Float(dw), cy = Float(ch) / Float(dh)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self), cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        // Optional buffers.
        var confPtr: UnsafePointer<UInt8>?
        var confRow = 0
        if let c = job.confidence, let base = CVPixelBufferGetBaseAddress(c),
           CVPixelBufferGetWidth(c) == dw, CVPixelBufferGetHeight(c) == dh {
            confPtr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            confRow = CVPixelBufferGetBytesPerRow(c)
        }
        var segPtr: UnsafePointer<UInt8>?
        var segRow = 0, segW = 0, segH = 0
        if let s = job.segmentation, let base = CVPixelBufferGetBaseAddress(s) {
            segPtr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            segRow = CVPixelBufferGetBytesPerRow(s)
            segW = CVPixelBufferGetWidth(s); segH = CVPixelBufferGetHeight(s)
        }
        let person = ARFrame.SegmentationClass.person.rawValue

        var added = false
        DepthUnprojection.extract(
            depth: depthBase.assumingMemoryBound(to: Float.self), depthRowFloats: depthRow, width: dw, height: dh,
            confidence: confPtr, confidenceRowBytes: confRow, minConfidence: options.minConfidence,
            maxRange: options.maxRange, intrinsics: k, cameraToWorld: job.cameraToWorld,
            isMasked: { x, y in
                guard let segPtr else { return false }
                let u = min(segW - 1, x * segW / dw), v = min(segH - 1, y * segH / dh)
                return segPtr[v * segRow + u] == person
            },
            color: { x, y in
                let ix = min(iw - 1, Int((Float(x) + 0.5) * sx)), iy = min(ih - 1, Int((Float(y) + 0.5) * sy))
                let cxI = min(cw - 1, Int((Float(x) + 0.5) * cx)), cyI = min(ch - 1, Int((Float(y) + 0.5) * cy))
                let c = cyI * cStride + cxI * 2
                return DepthUnprojection.rgb(y: yPtr[iy * yStride + ix], cb: cPtr[c], cr: cPtr[c + 1])
            },
            emit: { x, y, z, r, g, b in
                if case .added = cloud.insert(x, y, z, r, g, b) {
                    added = true
                    tailPositions += [x, y, z]
                    tailColors += [r, g, b, 255]
                }
            })
        guard added else { return }
        publish()
    }

    private func publish() {
        var frozen: [SCNGeometry] = []
        let chunk = Self.displayChunk
        let size = CGFloat(options.cellSize)
        while tailPositions.count >= chunk * 3 {
            frozen.append(PointGeometry.make(positions: tailPositions.prefix(chunk * 3).withUnsafeBufferPointer { Data(buffer: $0) },
                                             colors: Data(tailColors.prefix(chunk * 4)), count: chunk, pointSize: size))
            tailPositions.removeFirst(chunk * 3)
            tailColors.removeFirst(chunk * 4)
        }
        let n = tailPositions.count / 3
        let tail = n > 0
            ? PointGeometry.make(positions: tailPositions.withUnsafeBufferPointer { Data(buffer: $0) },
                                 colors: Data(tailColors), count: n, pointSize: size)
            : nil
        onUpdate(Update(frozen: frozen, tail: tail, count: cloud.count, capped: cloud.isFull))
    }
}
