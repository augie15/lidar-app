import Foundation
import SceneKit
import simd

/// Builds SceneKit point-primitive geometry from packed arrays.
enum PointGeometry {
    /// `positions`: packed float3. `colors`: packed RGBA8 (4 bytes per point) or nil for white.
    static func make(positions: Data, colors: Data?, count: Int, pointSize: CGFloat) -> SCNGeometry {
        var sources = [SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: count,
                                         usesFloatComponents: true, componentsPerVector: 3,
                                         bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
        if let colors {
            sources.append(SCNGeometrySource(data: colors, semantic: .color, vectorCount: count,
                                             usesFloatComponents: false, componentsPerVector: 4,
                                             bytesPerComponent: 1, dataOffset: 0, dataStride: 4))
        }
        let element = SCNGeometryElement(data: sequentialIndices(count), primitiveType: .point,
                                         primitiveCount: count, bytesPerIndex: 4)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 6
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PlatformColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static let indexLock = NSLock()
    nonisolated(unsafe) private static var chunkIndices: Data?

    /// 0..<count as UInt32. The live cloud's fixed-size chunks share one cached array.
    private static func sequentialIndices(_ count: Int) -> Data {
        let isChunk = count == PointCloudCapture.displayChunk
        if isChunk, let cached = indexLock.withLock({ chunkIndices }) { return cached }
        var idx = [UInt32](repeating: 0, count: count)
        for i in 0..<count { idx[i] = UInt32(i) }
        let data = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        if isChunk { indexLock.withLock { chunkIndices = data } }
        return data
    }

    /// Geometry for a PLY point cloud (RGB bytes).
    static func make(from cloud: PLYPointCloud.Cloud) -> SCNGeometry {
        let n = cloud.count
        let positions = cloud.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        var rgba: Data?
        if let c = cloud.colors {
            var bytes = [UInt8](repeating: 255, count: n * 4)
            for i in 0..<n {
                bytes[i * 4] = c[i * 3]; bytes[i * 4 + 1] = c[i * 3 + 1]; bytes[i * 4 + 2] = c[i * 3 + 2]
            }
            rgba = Data(bytes)
        }
        // Point size scales with the cloud: about 1/400 of its diagonal, clamped on screen by the element's radii.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<n {
            let p = SIMD3(cloud.positions[i * 3], cloud.positions[i * 3 + 1], cloud.positions[i * 3 + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        let diagonal = n > 0 ? simd_length(hi - lo) : 1
        return make(positions: positions, colors: rgba, count: n, pointSize: CGFloat(max(diagonal / 400, 0.002)))
    }
}

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif
