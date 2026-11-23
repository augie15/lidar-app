import Foundation
import simd

// Pure point cloud math and file IO (Foundation + simd only, so it can be tested from a Mac script).

/// Pinhole intrinsics in depth-map pixels.
struct DepthIntrinsics: Sendable {
    var fx: Float, fy: Float, cx: Float, cy: Float
}

/// Depth map pixel to camera space to world space.
///
/// Convention (same as `CameraProjection`): ARKit camera space looks down -Z with +Y up; the image is the landscape
/// sensor image with u right and v down. ARKit's depth map is aligned with the landscape camera image and stores
/// the distance along the optical axis (planar depth, not ray length), so for pixel (u, v) and depth d:
///     x = (u - cx) * d / fx
///     y = -(v - cy) * d / fy
///     z = -d
/// and world = cameraToWorld * (x, y, z, 1). `u`/`v` are pixel-corner coordinates, so pixel (i, j) is sampled at
/// (i + 0.5, j + 0.5).
enum DepthUnprojection {
    /// Scales the full-resolution camera intrinsics (`ARCamera.intrinsics`, image size `imageResolution`) to the
    /// depth map resolution.
    static func scaledIntrinsics(_ k: simd_float3x3, imageWidth: Float, imageHeight: Float,
                                 depthWidth: Int, depthHeight: Int) -> DepthIntrinsics {
        let sx = Float(depthWidth) / imageWidth
        let sy = Float(depthHeight) / imageHeight
        return DepthIntrinsics(fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy)
    }

    @inline(__always)
    static func cameraPoint(u: Float, v: Float, depth: Float, _ k: DepthIntrinsics) -> SIMD3<Float> {
        SIMD3((u - k.cx) * depth / k.fx, -(v - k.cy) * depth / k.fy, -depth)
    }

    /// Walks a depth map and emits one world-space point (plus color) per accepted pixel.
    /// - `confidence`: ARKit confidence map (0 low, 1 medium, 2 high), or nil to accept everything.
    /// - `isMasked`: depth-pixel (x, y) predicate, e.g. person segmentation.
    /// - `color`: depth-pixel (x, y) to RGB.
    static func extract(depth: UnsafePointer<Float>, depthRowFloats: Int, width: Int, height: Int,
                        confidence: UnsafePointer<UInt8>?, confidenceRowBytes: Int, minConfidence: UInt8,
                        minRange: Float = 0.1, maxRange: Float,
                        intrinsics k: DepthIntrinsics, cameraToWorld: simd_float4x4,
                        isMasked: (Int, Int) -> Bool,
                        color: (Int, Int) -> (UInt8, UInt8, UInt8),
                        emit: (Float, Float, Float, UInt8, UInt8, UInt8) -> Void) {
        for y in 0..<height {
            let row = depth + y * depthRowFloats
            let v = Float(y) + 0.5
            for x in 0..<width {
                let d = row[x]
                guard d.isFinite, d >= minRange, d <= maxRange else { continue }
                if let confidence, confidence[y * confidenceRowBytes + x] < minConfidence { continue }
                if isMasked(x, y) { continue }
                let c = cameraPoint(u: Float(x) + 0.5, v: v, depth: d, k)
                let w = cameraToWorld * SIMD4<Float>(c.x, c.y, c.z, 1)
                let rgb = color(x, y)
                emit(w.x, w.y, w.z, rgb.0, rgb.1, rgb.2)
            }
        }
    }

    /// Full-range YCbCr (ARKit's `capturedImage`) to RGB, same matrix as Apple's ARKit renderer sample.
    @inline(__always)
    static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let yy = Float(y), b = Float(cb) - 128, r = Float(cr) - 128
        func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v))) }
        return (clamp(yy + 1.402 * r), clamp(yy - 0.3441 * b - 0.7141 * r), clamp(yy + 1.772 * b))
    }
}

/// Voxel-hashed point store. Keeps one point per `cellSize` cube with a running average of position and color.
/// Not thread safe: use from one queue.
final class VoxelCloud: @unchecked Sendable {
    struct Point {
        var x: Float, y: Float, z: Float
        var r: UInt8, g: UInt8, b: UInt8
        var n: UInt8            // samples merged so far, capped
    }
    enum Result { case added(Int), merged, rejected }

    let cellSize: Float
    let maxPoints: Int
    private(set) var points: [Point] = []
    private var keys: [UInt64] = []
    private var slots: [UInt32]
    private var mask: Int
    private static let maxWeight: UInt8 = 7

    init(cellSize: Float, maxPoints: Int) {
        self.cellSize = cellSize
        self.maxPoints = maxPoints
        slots = [UInt32](repeating: 0, count: 1 << 16)
        mask = (1 << 16) - 1
    }

    var count: Int { points.count }
    var isFull: Bool { points.count >= maxPoints }

    @inline(__always)
    private func key(_ x: Float, _ y: Float, _ z: Float) -> UInt64 {
        let inv = 1 / cellSize
        func axis(_ v: Float) -> UInt64 {
            let i = Int((v * inv).rounded(.down)) + (1 << 20)
            return UInt64(max(0, min((1 << 21) - 1, i)))
        }
        return axis(x) | (axis(y) << 21) | (axis(z) << 42)
    }

    @inline(__always)
    private func slot(for key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 24) & mask
    }

    @discardableResult
    func insert(_ x: Float, _ y: Float, _ z: Float, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Result {
        let k = key(x, y, z)
        var s = slot(for: k)
        while true {
            let entry = slots[s]
            if entry == 0 { break }
            let i = Int(entry) - 1
            if keys[i] == k {
                var p = points[i]
                let w = 1 / (Float(p.n) + 1)
                p.x += (x - p.x) * w; p.y += (y - p.y) * w; p.z += (z - p.z) * w
                p.r = UInt8(max(0, min(255, Float(p.r) + (Float(r) - Float(p.r)) * w + 0.5)))
                p.g = UInt8(max(0, min(255, Float(p.g) + (Float(g) - Float(p.g)) * w + 0.5)))
                p.b = UInt8(max(0, min(255, Float(p.b) + (Float(b) - Float(p.b)) * w + 0.5)))
                if p.n < Self.maxWeight { p.n += 1 }
                points[i] = p
                return .merged
            }
            s = (s + 1) & mask
        }
        guard points.count < maxPoints else { return .rejected }
        if (points.count + 1) * 2 > slots.count {
            grow()
            s = slot(for: k)
            while slots[s] != 0 { s = (s + 1) & mask }
        }
        points.append(Point(x: x, y: y, z: z, r: r, g: g, b: b, n: 1))
        keys.append(k)
        slots[s] = UInt32(points.count)
        return .added(points.count - 1)
    }

    private func grow() {
        let size = slots.count * 2
        slots = [UInt32](repeating: 0, count: size)
        mask = size - 1
        for (i, k) in keys.enumerated() {
            var s = slot(for: k)
            while slots[s] != 0 { s = (s + 1) & mask }
            slots[s] = UInt32(i + 1)
        }
    }
}

enum PLYError: LocalizedError {
    case notPLY, unsupported(String), truncated
    var errorDescription: String? {
        switch self {
        case .notPLY: return "This file is not a PLY point cloud."
        case .unsupported(let s): return "Unsupported PLY file: \(s)."
        case .truncated: return "The PLY file is incomplete."
        }
    }
}

/// Binary little-endian PLY with `x y z` (float) and `red green blue` (uchar) per vertex.
enum PLYPointCloud {
    struct Cloud {
        var count: Int
        var positions: [Float]      // x y z per point
        var colors: [UInt8]?        // r g b per point
    }

    static func write(to url: URL, count: Int, vertex: (Int) -> (Float, Float, Float, UInt8, UInt8, UInt8)) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Tilda LiDAR point cloud, metres, +Y up
        element vertex \(count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let block = 65_536
        var buffer = [UInt8](repeating: 0, count: block * 15)
        var start = 0
        while start < count {
            let n = min(block, count - start)
            buffer.withUnsafeMutableBytes { raw in
                for j in 0..<n {
                    let v = vertex(start + j)
                    let o = j * 15
                    raw.storeBytes(of: v.0.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                    raw.storeBytes(of: v.1.bitPattern.littleEndian, toByteOffset: o + 4, as: UInt32.self)
                    raw.storeBytes(of: v.2.bitPattern.littleEndian, toByteOffset: o + 8, as: UInt32.self)
                    raw.storeBytes(of: v.3, toByteOffset: o + 12, as: UInt8.self)
                    raw.storeBytes(of: v.4, toByteOffset: o + 13, as: UInt8.self)
                    raw.storeBytes(of: v.5, toByteOffset: o + 14, as: UInt8.self)
                }
            }
            try handle.write(contentsOf: buffer.prefix(n * 15))
            start += n
        }
    }

    private struct Property { var name: String; var type: String; var offset: Int }

    private static func size(of type: String) -> Int? {
        switch type {
        case "char", "uchar", "int8", "uint8": return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "int", "uint", "int32", "uint32", "float", "float32": return 4
        case "double", "float64": return 8
        default: return nil
        }
    }

    /// Reads x/y/z and optional red/green/blue from the file's `vertex` element (binary little-endian or ASCII).
    static func read(_ url: URL) throws -> Cloud {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let marker = data.range(of: Data("end_header".utf8)) else { throw PLYError.notPLY }
        var bodyStart = marker.upperBound
        while bodyStart < data.count, data[bodyStart] != 0x0A { bodyStart += 1 }
        bodyStart += 1
        guard let header = String(data: data[data.startIndex..<marker.lowerBound], encoding: .ascii),
              header.hasPrefix("ply") else { throw PLYError.notPLY }

        var ascii = false
        var elements: [(name: String, count: Int, props: [Property], stride: Int, hasList: Bool)] = []
        for line in header.split(whereSeparator: \.isNewline) {
            let t = line.split(separator: " ").map(String.init)
            guard let head = t.first else { continue }
            switch head {
            case "format":
                guard t.count >= 2 else { throw PLYError.notPLY }
                if t[1] == "ascii" { ascii = true }
                else if t[1] != "binary_little_endian" { throw PLYError.unsupported(t[1]) }
            case "element":
                guard t.count >= 3, let n = Int(t[2]) else { throw PLYError.notPLY }
                elements.append((t[1], n, [], 0, false))
            case "property":
                guard !elements.isEmpty else { throw PLYError.notPLY }
                if t.count >= 5, t[1] == "list" { elements[elements.count - 1].hasList = true; continue }
                guard t.count >= 3, let sz = size(of: t[1]) else { throw PLYError.unsupported(line.description) }
                let i = elements.count - 1
                elements[i].props.append(Property(name: t[2], type: t[1], offset: elements[i].stride))
                elements[i].stride += sz
            default: break
            }
        }
        guard let vi = elements.firstIndex(where: { $0.name == "vertex" }) else { throw PLYError.unsupported("no vertices") }
        let v = elements[vi]
        guard let px = v.props.first(where: { $0.name == "x" }),
              let py = v.props.first(where: { $0.name == "y" }),
              let pz = v.props.first(where: { $0.name == "z" }) else { throw PLYError.unsupported("no x y z") }
        let pr = v.props.first { $0.name == "red" || $0.name == "r" }
        let pg = v.props.first { $0.name == "green" || $0.name == "g" }
        let pb = v.props.first { $0.name == "blue" || $0.name == "b" }
        let hasColor = pr != nil && pg != nil && pb != nil
        let n = v.count
        var positions = [Float](repeating: 0, count: n * 3)
        var colors = hasColor ? [UInt8](repeating: 255, count: n * 3) : []

        if ascii {
            guard let text = String(data: data[bodyStart...], encoding: .ascii) else { throw PLYError.truncated }
            var i = 0
            for line in text.split(whereSeparator: \.isNewline) {
                if i >= n { break }
                let f = line.split(separator: " ")
                guard f.count >= v.props.count else { throw PLYError.truncated }
                func val(_ p: Property) -> Float { Float(f[v.props.firstIndex { $0.name == p.name }!]) ?? 0 }
                positions[i * 3] = val(px); positions[i * 3 + 1] = val(py); positions[i * 3 + 2] = val(pz)
                if let pr, let pg, let pb {
                    colors[i * 3] = UInt8(max(0, min(255, val(pr))))
                    colors[i * 3 + 1] = UInt8(max(0, min(255, val(pg))))
                    colors[i * 3 + 2] = UInt8(max(0, min(255, val(pb))))
                }
                i += 1
            }
            guard i == n else { throw PLYError.truncated }
            return Cloud(count: n, positions: positions, colors: hasColor ? colors : nil)
        }

        // Vertex must be the first element, or only preceded by fixed-size elements.
        var base = bodyStart
        for e in elements[..<vi] {
            if e.hasList { throw PLYError.unsupported("variable-size element before vertices") }
            base += e.count * e.stride
        }
        if v.hasList { throw PLYError.unsupported("list property on vertex") }
        guard base + n * v.stride <= data.count else { throw PLYError.truncated }

        func load(_ p: Property, _ at: Int) -> Float {
            let o = at + p.offset
            switch p.type {
            case "float", "float32": return Float(bitPattern: data.loadLE(UInt32.self, o))
            case "double", "float64": return Float(Double(bitPattern: data.loadLE(UInt64.self, o)))
            case "uchar", "uint8": return Float(data[o])
            case "char", "int8": return Float(Int8(bitPattern: data[o]))
            case "short", "int16": return Float(Int16(bitPattern: data.loadLE(UInt16.self, o)))
            case "ushort", "uint16": return Float(data.loadLE(UInt16.self, o))
            case "int", "int32": return Float(Int32(bitPattern: data.loadLE(UInt32.self, o)))
            default: return Float(data.loadLE(UInt32.self, o))
            }
        }
        let colorIsFloat = pr.map { $0.type.hasPrefix("float") || $0.type == "double" } ?? false
        for i in 0..<n {
            let at = base + i * v.stride
            positions[i * 3] = load(px, at); positions[i * 3 + 1] = load(py, at); positions[i * 3 + 2] = load(pz, at)
            if let pr, let pg, let pb {
                let s: Float = colorIsFloat ? 255 : 1
                colors[i * 3] = UInt8(max(0, min(255, load(pr, at) * s)))
                colors[i * 3 + 1] = UInt8(max(0, min(255, load(pg, at) * s)))
                colors[i * 3 + 2] = UInt8(max(0, min(255, load(pb, at) * s)))
            }
        }
        return Cloud(count: n, positions: positions, colors: hasColor ? colors : nil)
    }
}

private extension Data {
    @inline(__always)
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, _ offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

/// Surface classification helpers that do not need ARKit.
enum SurfaceMath {
    struct Result {
        var positions: Data     // packed float3, 3 vertices per face (flat)
        var normals: Data
        var indices: Data       // UInt32, sequential
        var colors: Data        // packed float4 RGBA per vertex
        var faceCount: Int
        var areaByClass: [Int: Double]
    }

    /// De-indexes a world-space triangle mesh so each face owns its three vertices, colors every face by its class
    /// (`palette[class]`, RGB) and sums triangle areas per class. Faces with an index out of range are skipped.
    static func deindex(positions: [Float], indices: [UInt32], classes: [UInt8], palette: [SIMD3<Float>]) -> Result {
        let faces = indices.count / 3
        var pos = [Float](); pos.reserveCapacity(faces * 9)
        var nor = [Float](); nor.reserveCapacity(faces * 9)
        var col = [Float](); col.reserveCapacity(faces * 12)
        var area: [Int: Double] = [:]
        let vcount = positions.count / 3
        var kept = 0
        for f in 0..<faces {
            let i0 = Int(indices[f * 3]), i1 = Int(indices[f * 3 + 1]), i2 = Int(indices[f * 3 + 2])
            guard i0 < vcount, i1 < vcount, i2 < vcount else { continue }
            let a = SIMD3(positions[i0 * 3], positions[i0 * 3 + 1], positions[i0 * 3 + 2])
            let b = SIMD3(positions[i1 * 3], positions[i1 * 3 + 1], positions[i1 * 3 + 2])
            let c = SIMD3(positions[i2 * 3], positions[i2 * 3 + 1], positions[i2 * 3 + 2])
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            let n = len > 1e-12 ? cross / len : SIMD3<Float>(0, 1, 0)
            let cls = f < classes.count ? Int(classes[f]) : 0
            area[cls, default: 0] += Double(len) * 0.5
            let rgb = cls < palette.count ? palette[cls] : palette[0]
            for p in [a, b, c] {
                pos += [p.x, p.y, p.z]
                nor += [n.x, n.y, n.z]
                col += [rgb.x, rgb.y, rgb.z, 1]
            }
            kept += 1
        }
        let seq = (0..<UInt32(kept * 3)).map { $0 }
        return Result(positions: pos.withUnsafeBufferPointer { Data(buffer: $0) },
                      normals: nor.withUnsafeBufferPointer { Data(buffer: $0) },
                      indices: seq.withUnsafeBufferPointer { Data(buffer: $0) },
                      colors: col.withUnsafeBufferPointer { Data(buffer: $0) },
                      faceCount: kept, areaByClass: area)
    }
}
