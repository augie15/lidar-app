import ARKit
import SceneKit
import SwiftUI
import UIKit

/// ARKit mesh classification with display colors. Raw values match `ARMeshClassification`.
///
/// The palette is the Okabe-Ito color-blind-safe set, plus near-white for windows and grey for unclassified.
/// The legend always pairs each color with its name, so color is never the only cue.
enum SurfaceClass: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, wall, floor, ceiling, table, seat, window, door
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "Other"
        case .wall: "Wall"
        case .floor: "Floor"
        case .ceiling: "Ceiling"
        case .table: "Table"
        case .seat: "Seat"
        case .window: "Window"
        case .door: "Door"
        }
    }

    /// Key used in `surfaces.json`.
    var key: String { self == .none ? "other" : title.lowercased() }

    /// sRGB 0...1.
    var rgb: SIMD3<Float> {
        switch self {
        case .none: SIMD3(0.54, 0.54, 0.54)
        case .wall: SIMD3(0x56, 0xB4, 0xE9) / 255
        case .floor: SIMD3(0xE6, 0x9F, 0x00) / 255
        case .ceiling: SIMD3(0xCC, 0x79, 0xA7) / 255
        case .table: SIMD3(0xF0, 0xE4, 0x42) / 255
        case .seat: SIMD3(0xD5, 0x5E, 0x00) / 255
        case .window: SIMD3(0.95, 0.95, 0.97)
        case .door: SIMD3(0x00, 0x9E, 0x73) / 255
        }
    }

    var color: Color { Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
    var uiColor: UIColor { UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1) }

    static let palette: [SIMD3<Float>] = allCases.map(\.rgb)
}

/// World-space mesh with per-face class colors, plus the area of each class.
struct SurfaceSnapshot: @unchecked Sendable {
    var chunks: [WorldMeshChunk]
    var colors: [Data]
    var areaByClass: [SurfaceClass: Double]

    var isEmpty: Bool { chunks.isEmpty }

    /// `surfaces.json` body: area in square metres per class.
    func json() -> Data {
        var areas: [String: Double] = [:]
        for c in SurfaceClass.allCases { areas[c.key] = ((areaByClass[c] ?? 0) * 100).rounded() / 100 }
        let total = ((areaByClass.values.reduce(0, +)) * 100).rounded() / 100
        let doc: [String: Any] = ["unit": "m2", "areas": areas, "total": total]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}

enum SurfaceMesh {
    // MARK: Export

    /// Copies the anchors into world space, one flat-shaded chunk per anchor (each face owns its vertices, so class
    /// colors stay crisp at boundaries). The chunks and colors feed `MeshExporter.export(chunks:colors:)`.
    static func snapshot(_ anchors: [ARMeshAnchor]) -> SurfaceSnapshot {
        var chunks: [WorldMeshChunk] = []
        var colors: [Data] = []
        var area: [SurfaceClass: Double] = [:]
        for anchor in anchors {
            let geo = anchor.geometry
            let vCount = geo.vertices.count, fCount = geo.faces.count
            guard vCount > 0, fCount > 0, geo.faces.indexCountPerPrimitive == 3 else { continue }
            let m = anchor.transform

            var pos = [Float](repeating: 0, count: vCount * 3)
            let vBase = geo.vertices.buffer.contents().advanced(by: geo.vertices.offset)
            for i in 0..<vCount {
                let v = vBase.advanced(by: i * geo.vertices.stride).assumingMemoryBound(to: Float.self)
                let w = m * SIMD4<Float>(v[0], v[1], v[2], 1)
                pos[i * 3] = w.x; pos[i * 3 + 1] = w.y; pos[i * 3 + 2] = w.z
            }
            var idx = [UInt32](repeating: 0, count: fCount * 3)
            let fBase = geo.faces.buffer.contents()
            let bpi = geo.faces.bytesPerIndex
            for i in 0..<(fCount * 3) {
                let p = fBase.advanced(by: i * bpi)
                idx[i] = bpi == 4 ? p.loadUnaligned(as: UInt32.self) : UInt32(p.loadUnaligned(as: UInt16.self))
            }
            let classes = faceClasses(geo, count: fCount)

            let r = SurfaceMath.deindex(positions: pos, indices: idx, classes: classes, palette: SurfaceClass.palette)
            guard r.faceCount > 0 else { continue }
            chunks.append(WorldMeshChunk(positions: r.positions, normals: r.normals, indices: r.indices,
                                         vertexCount: r.faceCount * 3, faceCount: r.faceCount))
            colors.append(r.colors)
            for (k, a) in r.areaByClass { area[SurfaceClass(rawValue: k) ?? .none, default: 0] += a }
        }
        return SurfaceSnapshot(chunks: chunks, colors: colors, areaByClass: area)
    }

    /// Per-face class raw values (0 when the mesh was not classified).
    static func faceClasses(_ geo: ARMeshGeometry, count: Int) -> [UInt8] {
        guard let source = geo.classification else { return [UInt8](repeating: 0, count: count) }
        let base = source.buffer.contents().advanced(by: source.offset)
        return (0..<count).map { base.advanced(by: $0 * source.stride).loadUnaligned(as: UInt8.self) }
    }

    // MARK: Live display

    /// SceneKit geometry for one mesh anchor, split into one element per class so each gets its own material.
    /// Vertex and normal sources read ARKit's Metal buffers directly (no copy).
    nonisolated static func liveGeometry(for anchor: ARMeshAnchor) -> SCNGeometry {
        let geo = anchor.geometry
        let v = geo.vertices, n = geo.normals
        let vertexSource = SCNGeometrySource(buffer: v.buffer, vertexFormat: v.format, semantic: .vertex,
                                             vertexCount: v.count, dataOffset: v.offset, dataStride: v.stride)
        let normalSource = SCNGeometrySource(buffer: n.buffer, vertexFormat: n.format, semantic: .normal,
                                             vertexCount: n.count, dataOffset: n.offset, dataStride: n.stride)
        let faceCount = geo.faces.count
        let bpi = geo.faces.bytesPerIndex
        let fBase = geo.faces.buffer.contents()
        let classes = faceClasses(geo, count: faceCount)

        var perClass = [[UInt32]](repeating: [], count: SurfaceClass.allCases.count)
        for f in 0..<faceCount {
            let cls = min(Int(classes[f]), perClass.count - 1)
            for k in 0..<3 {
                let p = fBase.advanced(by: (f * 3 + k) * bpi)
                perClass[cls].append(bpi == 4 ? p.loadUnaligned(as: UInt32.self) : UInt32(p.loadUnaligned(as: UInt16.self)))
            }
        }
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for (cls, indices) in perClass.enumerated() where !indices.isEmpty {
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
            materials.append(material(for: SurfaceClass(rawValue: cls) ?? .none))
        }
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
        geometry.materials = materials
        return geometry
    }

    private nonisolated static func material(for cls: SurfaceClass) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = cls.uiColor
        m.transparency = 0.82
        m.isDoubleSided = true
        return m
    }
}

/// Small legend shown while scanning in Surfaces mode.
struct SurfaceLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SurfaceClass.allCases) { cls in
                HStack(spacing: 8) {
                    Circle().fill(cls.color).frame(width: 10, height: 10)
                    Text(cls.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: " + SurfaceClass.allCases.map(\.title).joined(separator: ", "))
    }
}
