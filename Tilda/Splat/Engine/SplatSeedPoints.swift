import Foundation
import ModelIO
import simd

/// The starting points a splat grows from. The scan's own geometry is a far better start than random dust: the LiDAR
/// point cloud as is, or points sampled over the room/mesh surface and coloured from the photos.
enum SplatSeedPoints {
    struct Seeds: Sendable {
        var xyz: [Float]
        var rgb: [UInt8]
        var count: Int { xyz.count / 3 }
    }

    /// Most points handed to the trainer. More than this only slows the first steps down.
    static let maxPoints = 150_000
    /// Points sampled over a surface model (RoomPlan walls, LiDAR mesh).
    static let surfacePoints = 120_000
    private static let minimumUseful = 1_000
    /// Same numbers every run, so a resumed training run starts from the same points as the first one.
    private static let seed: UInt64 = 0x71_1D_A5

    /// Seed points for a scan. `keyframes` are the photos used to colour points that have no colour. Falls back to
    /// points spread in front of the cameras when the model cannot be read, so training can still run.
    static func build(modelURL: URL, keyframes: [ColorKeyframe]) -> Seeds? {
        let colorFrames = colorKeyframes(keyframes)
        if modelURL.pathExtension.lowercased() == "ply", let seeds = fromPLY(modelURL, keyframes: colorFrames) { return seeds }
        if modelURL.pathExtension.lowercased() != "ply", let seeds = fromSurface(modelURL, keyframes: colorFrames) { return seeds }
        return fromCameras(keyframes, colorFrames: colorFrames)
    }

    // MARK: Point-cloud scans

    private static func fromPLY(_ url: URL, keyframes: [ColorKeyframe]) -> Seeds? {
        guard let cloud = try? PLYPointCloud.read(url), cloud.count >= minimumUseful else { return nil }
        let pick = SplatMath.evenIndices(count: cloud.count, limit: maxPoints)
        var xyz = [Float](), rgb = [UInt8]()
        xyz.reserveCapacity(pick.count * 3); rgb.reserveCapacity(pick.count * 3)
        for i in pick {
            xyz.append(cloud.positions[i * 3]); xyz.append(cloud.positions[i * 3 + 1]); xyz.append(cloud.positions[i * 3 + 2])
            if let colors = cloud.colors {
                rgb.append(colors[i * 3]); rgb.append(colors[i * 3 + 1]); rgb.append(colors[i * 3 + 2])
            }
        }
        if cloud.colors == nil { rgb = colorize(xyz, normals: nil, keyframes: keyframes) }
        return Seeds(xyz: xyz, rgb: rgb)
    }

    // MARK: Surface models (RoomPlan rooms, LiDAR meshes, objects)

    private static func fromSurface(_ url: URL, keyframes: [ColorKeyframe]) -> Seeds? {
        let triangles = loadTriangles(url)
        guard triangles.count >= 3 else { return nil }
        let sampled = SplatMath.sampleSurface(triangles: triangles, count: surfacePoints, seed: seed)
        guard sampled.points.count >= minimumUseful else { return nil }
        let xyz = sampled.points.flatMap { [$0.x, $0.y, $0.z] }
        let normals = sampled.normals.flatMap { [$0.x, $0.y, $0.z] }
        return Seeds(xyz: xyz, rgb: colorize(xyz, normals: normals, keyframes: keyframes))
    }

    /// Every triangle of the model in world space, 3 vertices each. ModelIO reads USDZ on all devices; RoomPlan walls,
    /// floor and objects are ordinary meshes in it. Quads are split into two triangles.
    static func loadTriangles(_ url: URL) -> [SIMD3<Float>] {
        let asset = MDLAsset(url: url)
        var out: [SIMD3<Float>] = []
        for mesh in asset.childObjects(of: MDLMesh.self).compactMap({ $0 as? MDLMesh }) {
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  let submeshes = mesh.submeshes as? [MDLSubmesh] else { continue }
            let toWorld = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let base = positions.dataStart, stride = positions.stride
            func vertex(_ i: Int) -> SIMD3<Float> {
                let p = base.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
                let w = toWorld * SIMD4(p[0], p[1], p[2], 1)
                return SIMD3(w.x, w.y, w.z)
            }
            let vertexCount = mesh.vertexCount
            for sub in submeshes {
                let idx = sub.indexBuffer(asIndexType: .uInt32)
                let map = idx.map()
                let ids = map.bytes.assumingMemoryBound(to: UInt32.self)
                let n = sub.indexCount
                switch sub.geometryType {
                case .triangles:
                    var t = 0
                    while t + 2 < n {
                        let a = Int(ids[t]), b = Int(ids[t + 1]), c = Int(ids[t + 2])
                        if a < vertexCount, b < vertexCount, c < vertexCount { out += [vertex(a), vertex(b), vertex(c)] }
                        t += 3
                    }
                case .quads:
                    var t = 0
                    while t + 3 < n {
                        let a = Int(ids[t]), b = Int(ids[t + 1]), c = Int(ids[t + 2]), d = Int(ids[t + 3])
                        if a < vertexCount, b < vertexCount, c < vertexCount, d < vertexCount {
                            out += [vertex(a), vertex(b), vertex(c), vertex(a), vertex(c), vertex(d)]
                        }
                        t += 4
                    }
                default: break
                }
            }
        }
        return out
    }

    // MARK: Fallback

    /// Points scattered 1-4 m in front of the cameras: a rough start when no usable model exists.
    private static func fromCameras(_ all: [ColorKeyframe], colorFrames: [ColorKeyframe]) -> Seeds? {
        guard !all.isEmpty else { return nil }
        var rng = SplatMath.SplitMix64(seed: seed)
        let frames = SplatMath.evenIndices(count: all.count, limit: 300).map { all[$0] }
        let perFrame = max(1, 30_000 / frames.count)
        var xyz = [Float]()
        for f in frames {
            for _ in 0..<perFrame {
                let u = Float.random(in: 0.1..<0.9, using: &rng) * Float(f.width)
                let v = Float.random(in: 0.1..<0.9, using: &rng) * Float(f.height)
                let depth = Float.random(in: 1..<4, using: &rng)
                let cam = SIMD4((u - f.cx) * depth / f.fx, -(v - f.cy) * depth / f.fy, -depth, 1)
                let w = f.cameraToWorld * cam
                xyz += [w.x, w.y, w.z]
            }
        }
        guard xyz.count >= 3 else { return nil }
        return Seeds(xyz: xyz, rgb: colorize(xyz, normals: nil, keyframes: colorFrames))
    }

    // MARK: Colour

    /// Enough evenly spread photos to colour from; each costs a decode and a pass over every point.
    private static func colorKeyframes(_ all: [ColorKeyframe]) -> [ColorKeyframe] {
        SplatMath.evenIndices(count: all.count, limit: 150).map { all[$0] }
    }

    /// Colours points from the photos with the same projection Tilda uses for mesh scans. Unseen points are mid grey.
    private static func colorize(_ xyz: [Float], normals: [Float]?, keyframes: [ColorKeyframe]) -> [UInt8] {
        let count = xyz.count / 3
        let positions = xyz.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = (normals ?? [Float](repeating: 0, count: xyz.count)).withUnsafeBufferPointer { Data(buffer: $0) }
        guard !keyframes.isEmpty,
              let rgba = MeshColorizer.colorize(positions: [positions], normals: [normalData], keyframes: keyframes).first,
              rgba.count >= count * 16 else { return [UInt8](repeating: 128, count: count * 3) }
        var rgb = [UInt8](repeating: 128, count: count * 3)
        rgba.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                for c in 0..<3 { rgb[i * 3 + c] = UInt8(max(0, min(255, f[i * 4 + c] * 255))) }
            }
        }
        return rgb
    }
}

#if DEBUG
extension SplatSeedPoints {
    /// Writes a small box with ModelIO, reads it back through `loadTriangles`, and checks the geometry.
    static func selfCheck() -> [String] {
        guard MDLAsset.canExportFileExtension("usda") else { return [] }   // nothing to round-trip with
        let box = MDLMesh.newBox(withDimensions: SIMD3(2, 2, 2), segments: SIMD3(1, 1, 1), geometryType: .triangles,
                                 inwardNormals: false, allocator: nil)
        let asset = MDLAsset()
        asset.add(box)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilda-selfcheck-box.usda")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try asset.export(to: url) } catch { return [] }
        let tris = loadTriangles(url)
        var failures: [String] = []
        if tris.count != 36 { failures.append("box has 12 triangles (got \(tris.count / 3))") }
        let area = stride(from: 0, to: tris.count - 2, by: 3).reduce(Float(0)) {
            $0 + simd_length(simd_cross(tris[$1 + 1] - tris[$1], tris[$1 + 2] - tris[$1])) / 2
        }
        if abs(area - 24) > 0.1 { failures.append("box surface area is 24 (got \(area))") }
        return failures
    }
}
#endif
