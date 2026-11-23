import ARKit
import simd

/// World-space axis-aligned box that bounds the object.
struct CropBox: Sendable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>
    /// World Y of the surface the object sits on.
    var bottom: Float
}

/// One mesh anchor's world-space geometry plus per-face surface classes (when ARKit provides them).
struct ClassifiedChunk: @unchecked Sendable {
    let chunk: WorldMeshChunk
    let classes: [UInt8]?
}

/// Cuts the scene mesh down to the object: keeps triangles inside the box, drops the support surface.
enum LidarMeshCropper {
    /// Reads anchors near the box on the calling thread (uses `MeshExporter.snapshot` for the geometry itself).
    static func snapshot(_ anchors: [ARMeshAnchor], near box: CropBox) -> [ClassifiedChunk] {
        let center = (box.min + box.max) / 2
        let reach = simd_length(box.max - box.min) / 2 + 5
        return anchors.compactMap { anchor in
            let t = anchor.transform.columns.3
            guard simd_distance(SIMD3(t.x, t.y, t.z), center) <= reach,
                  let chunk = MeshExporter.snapshot([anchor]).first else { return nil }
            var classes: [UInt8]?
            if let source = anchor.geometry.classification {
                let base = source.buffer.contents().advanced(by: source.offset)
                classes = (0..<chunk.faceCount).map { base.advanced(by: $0 * source.stride).load(as: UInt8.self) }
            }
            return ClassifiedChunk(chunk: chunk, classes: classes)
        }
    }

    /// Keeps triangles whose three vertices lie inside the box (1 cm margin). Drops faces classified as floor and
    /// flat slivers within 12 mm of the support surface (tables and shelves are not "floor").
    static func crop(_ snaps: [ClassifiedChunk], box: CropBox) -> [WorldMeshChunk] {
        let margin = SIMD3<Float>(repeating: 0.01)
        let lo = box.min - margin, hi = box.max + margin
        let floorY = box.bottom + 0.012
        let floorClass = UInt8(ARMeshClassification.floor.rawValue)

        var out: [WorldMeshChunk] = []
        for snap in snaps {
            let c = snap.chunk
            let pos: [Float] = c.positions.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(c.vertexCount * 3)) }
            let nor: [Float] = c.normals.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(c.vertexCount * 3)) }
            let idx: [UInt32] = c.indices.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self).prefix(c.faceCount * 3)) }
            guard pos.count == c.vertexCount * 3, nor.count == pos.count, idx.count == c.faceCount * 3 else { continue }

            func vertex(_ i: Int) -> SIMD3<Float> { SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]) }

            var remap = [Int32](repeating: -1, count: c.vertexCount)
            var newPos: [Float] = [], newNor: [Float] = [], newIdx: [UInt32] = []
            for f in 0..<c.faceCount {
                if let classes = snap.classes, f < classes.count, classes[f] == floorClass { continue }
                let ids = (Int(idx[f * 3]), Int(idx[f * 3 + 1]), Int(idx[f * 3 + 2]))
                let a = vertex(ids.0), b = vertex(ids.1), d = vertex(ids.2)
                let inside = [a, b, d].allSatisfy { all($0 .>= lo) && all($0 .<= hi) }
                guard inside else { continue }
                if Swift.max(a.y, b.y, d.y) < floorY { continue }
                for id in [ids.0, ids.1, ids.2] {
                    if remap[id] < 0 {
                        remap[id] = Int32(newPos.count / 3)
                        newPos += [pos[id * 3], pos[id * 3 + 1], pos[id * 3 + 2]]
                        newNor += [nor[id * 3], nor[id * 3 + 1], nor[id * 3 + 2]]
                    }
                    newIdx.append(UInt32(remap[id]))
                }
            }
            guard !newIdx.isEmpty else { continue }
            out.append(WorldMeshChunk(positions: newPos.withUnsafeBufferPointer { Data(buffer: $0) },
                                      normals: newNor.withUnsafeBufferPointer { Data(buffer: $0) },
                                      indices: newIdx.withUnsafeBufferPointer { Data(buffer: $0) },
                                      vertexCount: newPos.count / 3, faceCount: newIdx.count / 3))
        }
        return out
    }
}
