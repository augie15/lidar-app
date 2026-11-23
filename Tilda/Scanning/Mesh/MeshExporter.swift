import ARKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

/// Raw, Sendable copy of one mesh anchor's geometry, already in world space.
struct WorldMeshChunk: @unchecked Sendable {
    let positions: Data      // packed float3 (12 bytes each)
    let normals: Data        // packed float3
    let indices: Data        // UInt32
    let vertexCount: Int
    let faceCount: Int
}

enum MeshExporter {
    /// Snapshot the anchors' geometry on the calling thread (cheap memcpy-style reads).
    static func snapshot(_ anchors: [ARMeshAnchor]) -> [WorldMeshChunk] {
        anchors.compactMap { chunk(for: $0) }
    }

    private static func chunk(for anchor: ARMeshAnchor) -> WorldMeshChunk? {
        let geo = anchor.geometry
        let vCount = geo.vertices.count
        let fCount = geo.faces.count
        guard vCount > 0, fCount > 0 else { return nil }
        let m = anchor.transform
        let normalM = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                    SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                    SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))

        var pos = [Float](repeating: 0, count: vCount * 3)
        var nor = [Float](repeating: 0, count: vCount * 3)
        let vBase = geo.vertices.buffer.contents().advanced(by: geo.vertices.offset)
        let nBase = geo.normals.buffer.contents().advanced(by: geo.normals.offset)
        for i in 0..<vCount {
            let v = vBase.advanced(by: i * geo.vertices.stride).assumingMemoryBound(to: Float.self)
            let w = m * SIMD4<Float>(v[0], v[1], v[2], 1)
            pos[i * 3] = w.x; pos[i * 3 + 1] = w.y; pos[i * 3 + 2] = w.z
            let n = nBase.advanced(by: i * geo.normals.stride).assumingMemoryBound(to: Float.self)
            let nw = simd_normalize(normalM * SIMD3<Float>(n[0], n[1], n[2]))
            nor[i * 3] = nw.x; nor[i * 3 + 1] = nw.y; nor[i * 3 + 2] = nw.z
        }

        let indexCount = fCount * geo.faces.indexCountPerPrimitive
        var idx = [UInt32](repeating: 0, count: indexCount)
        let fBase = geo.faces.buffer.contents()
        let bpi = geo.faces.bytesPerIndex
        for i in 0..<indexCount {
            let p = fBase.advanced(by: i * bpi)
            idx[i] = bpi == 4 ? p.loadUnaligned(as: UInt32.self) : UInt32(p.loadUnaligned(as: UInt16.self))
        }

        return WorldMeshChunk(positions: pos.withUnsafeBufferPointer { Data(buffer: $0) },
                              normals: nor.withUnsafeBufferPointer { Data(buffer: $0) },
                              indices: idx.withUnsafeBufferPointer { Data(buffer: $0) },
                              vertexCount: vCount, faceCount: fCount)
    }

    /// Builds an MDLAsset and writes it to a fresh temp folder. Prefers USDZ, falls back to OBJ.
    /// `colors`, when given, holds one packed float4 (RGBA) array per chunk and is written as the vertex color attribute.
    static func export(chunks: [WorldMeshChunk], colors: [Data]? = nil) throws -> URL {
        guard !chunks.isEmpty else { throw MeshExportError.empty }
        let allocator = MDLMeshBufferDataAllocator()
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 0, bufferIndex: 1)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        descriptor.layouts[1] = MDLVertexBufferLayout(stride: 12)
        let hasColors = colors?.count == chunks.count
        if hasColors {
            descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float4, offset: 0, bufferIndex: 2)
            descriptor.layouts[2] = MDLVertexBufferLayout(stride: 16)
        }

        let asset = MDLAsset()
        for (i, c) in chunks.enumerated() {
            let vb = allocator.newBuffer(with: c.positions, type: .vertex)
            let nb = allocator.newBuffer(with: c.normals, type: .vertex)
            let ib = allocator.newBuffer(with: c.indices, type: .index)
            let sub = MDLSubmesh(indexBuffer: ib, indexCount: c.faceCount * 3, indexType: .uInt32,
                                 geometryType: .triangles, material: nil)
            var buffers = [vb, nb]
            if hasColors, let colors, colors[i].count == c.vertexCount * 16 {
                buffers.append(allocator.newBuffer(with: colors[i], type: .vertex))
            } else if hasColors {
                // Keep buffer layout consistent if one chunk has no colors: neutral grey.
                let grey = [Float](repeating: 0.5, count: c.vertexCount * 4)
                buffers.append(allocator.newBuffer(with: grey.withUnsafeBufferPointer { Data(buffer: $0) }, type: .vertex))
            }
            let mesh = MDLMesh(vertexBuffers: buffers, vertexCount: c.vertexCount,
                               descriptor: descriptor, submeshes: [sub])
            asset.add(mesh)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ModelIO can't write .usdz, but SceneKit can. USDZ keeps the scan previewable in Quick Look and AR.
        let usdzURL = dir.appendingPathComponent("mesh.usdz")
        if SCNScene(mdlAsset: asset).write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil),
           FileManager.default.fileExists(atPath: usdzURL.path) {
            return usdzURL
        }
        guard MDLAsset.canExportFileExtension("obj") else { throw MeshExportError.unsupported }
        let objURL = dir.appendingPathComponent("mesh.obj")
        try asset.export(to: objURL)
        return objURL
    }
}

extension MeshExporter {
    /// Writes the deduped point cloud as binary little-endian `model.ply` (x y z float, red green blue uchar).
    static func exportPointCloud(_ cloud: VoxelCloud) throws -> URL {
        guard cloud.count > 0 else { throw MeshExportError.noPoints }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("model.ply")
        let points = cloud.points
        try PLYPointCloud.write(to: url, count: points.count) { i in
            let p = points[i]
            return (p.x, p.y, p.z, p.r, p.g, p.b)
        }
        return url
    }

    /// Writes `surfaces.json` (square metres per class) into a fresh temp folder.
    static func writeSurfaces(_ snapshot: SurfaceSnapshot) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("surfaces.json")
        try snapshot.json().write(to: url)
        return url
    }
}

enum MeshExportError: LocalizedError {
    case empty, unsupported, noPoints
    var errorDescription: String? {
        switch self {
        case .noPoints: return "No points were captured yet. Move around to scan some surfaces, then try again."
        case .empty: return "No mesh was captured yet. Move around to scan some surfaces, then try again."
        case .unsupported: return "This device cannot export 3D model files."
        }
    }
}
