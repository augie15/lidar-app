import Foundation
import ImageIO
import simd

/// Pure helpers for the splat engine: pose conversion, photo scoring, point sampling. No files, no Metal, no Vision,
/// so they can be checked on their own (see `selfCheck`).
enum SplatMath {
    // MARK: Camera convention

    /// ARKit camera-to-world -> msplat camera-to-world (16 floats, ROW-major).
    ///
    /// msplat's `DatasetFrame.cameraToWorld` is "OpenGL, Y-up, Z-back": camera +X right, +Y up, looking down -Z. That
    /// is exactly the ARKit camera convention (and what `transforms.json` stores), and our photos are the raw landscape
    /// sensor images ARKit's intrinsics belong to, so `rasterOrientation` is `.encodedPixels` and no axis flip or
    /// rotation is needed. The only change is layout: simd is column-major, msplat wants row-major.
    static func msplatPose(fromARKit m: simd_float4x4) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(16)
        for row in 0..<4 { for col in 0..<4 { out.append(m[col][row]) } }
        return out
    }

    /// Where a world point lands in the image under msplat's convention (pixels, origin top-left, +v down), given the
    /// row-major pose from `msplatPose`. Nil when the point is behind the camera.
    static func project(world: SIMD3<Float>, rowMajorPose p: [Float], fx: Float, fy: Float, cx: Float, cy: Float)
        -> SIMD2<Float>? {
        var m = matrix_identity_float4x4
        for row in 0..<4 { for col in 0..<4 { m[col][row] = p[row * 4 + col] } }
        let c = m.inverse * SIMD4(world.x, world.y, world.z, 1)
        guard -c.z > 0.01 else { return nil }
        return SIMD2(fx * c.x / -c.z + cx, cy - fy * c.y / -c.z)
    }

    /// How to turn a raw sensor photo upright, from where world "up" points in camera space. Phones are held in
    /// portrait, so the raw landscape photo lies on its side (ARKit's landscape-right sensor): rotate it clockwise.
    static func uprightOrientation(worldUpInCamera u: SIMD3<Float>) -> CGImagePropertyOrientation {
        if abs(u.y) >= abs(u.x) { return u.y >= 0 ? .up : .down }
        return u.x < 0 ? .right : .left
    }

    static func uprightOrientation(cameraToWorld m: simd_float4x4) -> CGImagePropertyOrientation {
        // World up expressed in camera axes = the world Y components of the camera's X, Y, Z columns.
        uprightOrientation(worldUpInCamera: SIMD3(m.columns.0.y, m.columns.1.y, m.columns.2.y))
    }

    /// The orientation that undoes `o` (turns an upright image back into raw sensor pixels).
    static func inverse(of o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .right: return .left
        case .left: return .right
        default: return o
        }
    }

    // MARK: Photo scoring

    /// Variance of the Laplacian of an 8-bit grayscale image: high when edges are crisp, low when blurred.
    static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Float {
        guard width >= 3, height >= 3, gray.count >= width * height else { return 0 }
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        gray.withUnsafeBufferPointer { g in
            for y in 1..<(height - 1) {
                let row = y * width
                for x in 1..<(width - 1) {
                    let i = row + x
                    let lap = 4 * Int(g[i]) - Int(g[i - 1]) - Int(g[i + 1]) - Int(g[i - width]) - Int(g[i + width])
                    let d = Double(lap)
                    sum += d; sumSq += d * d; n += 1
                }
            }
        }
        let mean = sum / n
        return Float(max(0, sumSq / n - mean * mean))
    }

    /// Indices (in original order) of the photos to keep: drops the blurriest `dropFraction`, but never leaves fewer
    /// than `minimum` photos.
    static func keepIndices(scores: [Float], dropFraction: Float, minimum: Int) -> [Int] {
        let n = scores.count
        let drop = min(Int(Float(n) * dropFraction), max(0, n - minimum))
        guard drop > 0 else { return Array(0..<n) }
        // Lowest scores first; ties broken by index so the choice is repeatable (checkpoint resume relies on it).
        let order = (0..<n).sorted { a, b in
            let sa = scores[a].isFinite ? scores[a] : 0, sb = scores[b].isFinite ? scores[b] : 0
            return sa != sb ? sa < sb : a < b
        }
        let dropped = Set(order.prefix(drop))
        return (0..<n).filter { !dropped.contains($0) }
    }

    /// At most `limit` evenly spread indices out of `0..<count`.
    static func evenIndices(count: Int, limit: Int) -> [Int] {
        guard count > limit, limit > 0 else { return Array(0..<max(0, count)) }
        return (0..<limit).map { $0 * count / limit }
    }

    // MARK: Seed points

    /// Repeatable random numbers so a resumed run builds the same seed points.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Area-weighted random points on triangles (`triangles` holds 3 vertices per triangle) with each point's face
    /// normal. Big triangles get proportionally more points, so a boxy RoomPlan wall is covered as evenly as a mesh.
    static func sampleSurface(triangles: [SIMD3<Float>], count: Int, seed: UInt64)
        -> (points: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        let triCount = triangles.count / 3
        guard triCount > 0, count > 0 else { return ([], []) }
        var cumulative = [Double](repeating: 0, count: triCount)
        var total = 0.0
        for t in 0..<triCount {
            let a = triangles[t * 3], b = triangles[t * 3 + 1], c = triangles[t * 3 + 2]
            let area = Double(simd_length(simd_cross(b - a, c - a))) * 0.5
            total += area.isFinite ? area : 0
            cumulative[t] = total
        }
        guard total > 0 else { return ([], []) }
        var rng = SplitMix64(seed: seed)
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(count); normals.reserveCapacity(count)
        for _ in 0..<count {
            let target = Double.random(in: 0..<total, using: &rng)
            var lo = 0, hi = triCount - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            let a = triangles[lo * 3], b = triangles[lo * 3 + 1], c = triangles[lo * 3 + 2]
            let r1 = Float.random(in: 0..<1, using: &rng).squareRoot(), r2 = Float.random(in: 0..<1, using: &rng)
            points.append((1 - r1) * a + r1 * (1 - r2) * b + r1 * r2 * c)
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            normals.append(len > 1e-9 ? n / len : SIMD3(0, 1, 0))
        }
        return (points, normals)
    }
}

#if DEBUG
extension SplatMath {
    /// Device-free checks of the camera convention and the photo/point helpers. Run with `-TildaSelfCheck`.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // Motion blur: 30 degrees per second, 1/60 s exposure, fx 1500 -> 0.5236 * (1/60) * 1500 = 13.1 px.
        var turned = matrix_identity_float4x4
        let a30: Float = 30 * .pi / 180 * 0.1          // 0.1 s at 30 degrees per second
        turned.columns.0 = SIMD4(cos(a30), 0, -sin(a30), 0)
        turned.columns.2 = SIMD4(sin(a30), 0, cos(a30), 0)
        let blur = FrameRecorder.motionBlurPixels(from: matrix_identity_float4x4, to: turned, dt: 0.1, exposure: 1.0 / 60, fx: 1500)
        expect(abs(blur - 13.09) < 0.2, "blur from turning is about 13 px (got \(blur))")
        expect(FrameRecorder.motionBlurPixels(from: turned, to: turned, dt: 0.1, exposure: 1.0 / 60, fx: 1500) < 0.01, "no turn, no blur")
        failures += SplatReadiness.selfCheck()

        // Heat: run when normal or fair, hold at serious, stop at critical.
        expect(SplatTrainer.thermalAction(.nominal) == .run && SplatTrainer.thermalAction(.fair) == .run, "runs when cool")
        expect(SplatTrainer.thermalAction(.serious) == .cool, "holds to cool at serious")
        expect(SplatTrainer.thermalAction(.critical) == .stop, "stops at critical")

        // A camera at (1, 1.4, 2), turned 90 degrees left about world Y: its -Z axis now looks along world -X.
        let yaw: Float = .pi / 2
        let cameraToWorld = simd_float4x4(columns: (
            SIMD4(cos(yaw), 0, -sin(yaw), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(yaw), 0, cos(yaw), 0), SIMD4(1, 1.4, 2, 1)))
        let pose = msplatPose(fromARKit: cameraToWorld)
        expect(pose.count == 16, "pose has 16 values")
        // Row-major: translation sits in the last column; the rotation's first row is (cos, 0, sin).
        expect(pose[3] == 1 && pose[7] == 1.4 && pose[11] == 2 && pose[15] == 1, "translation is the last column")
        expect(abs(pose[0] - cos(yaw)) < 1e-6 && abs(pose[2] - sin(yaw)) < 1e-6, "rotation is row-major")

        // A point 2 m ahead (world -X) and 0.5 m to the camera's right lands right of centre; the camera's right is
        // world -Z. 1 m above the camera's height lands above centre (smaller v).
        let fx: Float = 1500, fy: Float = 1500, cx: Float = 960, cy: Float = 720
        let ahead = SIMD3<Float>(1 - 2, 1.4, 2)
        let right = SIMD3<Float>(1 - 2, 1.4, 2 - 0.5)
        let above = SIMD3<Float>(1 - 2, 2.4, 2)
        let p0 = project(world: ahead, rowMajorPose: pose, fx: fx, fy: fy, cx: cx, cy: cy)
        let p1 = project(world: right, rowMajorPose: pose, fx: fx, fy: fy, cx: cx, cy: cy)
        let p2 = project(world: above, rowMajorPose: pose, fx: fx, fy: fy, cx: cx, cy: cy)
        expect(p0.map { abs($0.x - cx) < 0.01 && abs($0.y - cy) < 0.01 } ?? false, "point straight ahead hits the centre")
        expect(p1.map { abs($0.x - (cx + fx * 0.25)) < 0.05 && abs($0.y - cy) < 0.01 } ?? false, "point to the right lands right")
        expect(p2.map { abs($0.x - cx) < 0.01 && $0.y < cy } ?? false, "point above lands above centre (v down)")
        expect(p1.map { $0.x >= 0 && $0.x < 1920 && $0.y >= 0 && $0.y < 1440 } ?? false, "visible point is inside the image")
        expect(project(world: SIMD3(1 + 2, 1.4, 2), rowMajorPose: pose, fx: fx, fy: fy, cx: cx, cy: cy) == nil, "point behind is rejected")

        // Same answer as the projection Tilda already uses for colouring.
        let reference = CameraProjection(cameraToWorld: cameraToWorld, fx: fx, fy: fy, cx: cx, cy: cy, width: 1920, height: 1440)
        if let r = reference.project(right), let q = p1 { expect(abs(r.u - q.x) < 0.01 && abs(r.v - q.y) < 0.01, "matches CameraProjection") }
        else { failures.append("CameraProjection did not project the test point") }

        // Photo orientation: upright camera, and a portrait-held phone (sensor X axis points world-down).
        expect(uprightOrientation(cameraToWorld: matrix_identity_float4x4) == .up, "level camera is upright")
        let portrait = simd_float4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.4, 0, 1)))
        expect(uprightOrientation(cameraToWorld: portrait) == .right, "portrait phone turns photo clockwise")
        expect(inverse(of: .right) == .left && inverse(of: .up) == .up, "orientation inverse")

        // Blur: a checkerboard scores far above a smoothed copy and a flat image scores zero.
        let w = 64, h = 64
        var sharp = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { sharp[y * w + x] = ((x / 2 + y / 2) % 2 == 0) ? 20 : 235 } }
        var soft = sharp
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            var s = 0
            for dy in -1...1 { for dx in -1...1 { s += Int(sharp[(y + dy) * w + x + dx]) } }
            soft[y * w + x] = UInt8(s / 9)
        } }
        let sharpScore = laplacianVariance(gray: sharp, width: w, height: h)
        let softScore = laplacianVariance(gray: soft, width: w, height: h)
        expect(sharpScore > softScore * 2, "sharp image outscores a blurred one")
        expect(laplacianVariance(gray: [UInt8](repeating: 90, count: w * h), width: w, height: h) == 0, "flat image scores zero")

        // Ranking: drops the blurriest 15%, never below the minimum.
        let scores: [Float] = (0..<20).map { Float(($0 * 7) % 20) }   // a permutation of 0...19
        let kept = keepIndices(scores: scores, dropFraction: 0.15, minimum: 5)
        expect(kept.count == 17 && !kept.contains(0) && !kept.contains(where: { scores[$0] < 3 }), "drops the 3 lowest of 20")
        expect(keepIndices(scores: scores, dropFraction: 0.15, minimum: 20).count == 20, "minimum blocks dropping")
        expect(keepIndices(scores: scores, dropFraction: 0.15, minimum: 19).count == 19, "minimum limits the drop")

        // Subsampling and surface sampling.
        let even = evenIndices(count: 1000, limit: 150)
        expect(even.count == 150 && Set(even).count == 150 && even.last! < 1000, "even subsample is unique and in range")
        expect(evenIndices(count: 10, limit: 150).count == 10, "small sets are left alone")
        let big: [SIMD3<Float>] = [[0, 0, 0], [10, 0, 0], [0, 10, 0]]     // area 50, normal +Z
        let tiny: [SIMD3<Float>] = [[20, 0, 0], [20.1, 0, 0], [20, 0.1, 0]] // area 0.005
        let s = sampleSurface(triangles: big + tiny, count: 5000, seed: 1)
        let onBig = s.points.filter { $0.x < 11 }.count
        expect(s.points.count == 5000 && onBig > 4950, "points are weighted by triangle area")
        expect(s.points.filter { $0.x < 11 }.allSatisfy { $0.x + $0.y <= 10.001 && $0.x >= 0 && $0.y >= 0 && $0.z == 0 }, "points stay on the triangle")
        expect(s.normals.first.map { simd_distance($0, SIMD3(0, 0, 1)) < 1e-4 } ?? false, "normal is the face normal")
        expect(sampleSurface(triangles: big, count: 10, seed: 7).points == sampleSurface(triangles: big, count: 10, seed: 7).points, "sampling repeats for the same seed")
        failures += SplatSeedPoints.selfCheck()
        return failures
    }
}
#endif
