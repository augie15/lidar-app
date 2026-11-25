#if DEBUG
import Foundation
import SplatIO
import simd

/// DEBUG only: a small synthetic room (about 70,000 splats, floor, four walls, a table and a sofa) in ARKit space
/// (metres, +Y up), so the viewer can be checked in the Simulator. Launch with `-TildaSplatSample YES`.
enum SplatDebugSample {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "TildaSplatSample") }

    static func write(to url: URL) async {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var points: [SplatPoint] = []
        var seed: UInt64 = 7
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xFFFF) / 65535
        }
        func add(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ size: Float) {
            let j = 0.9 + 0.2 * rnd()
            points.append(SplatPoint(position: p, color: .sRGBUInt8(SIMD3<UInt8>(simd_clamp(c * j, .zero, .one) * 255)),
                                     opacity: .linearFloat(0.9),
                                     scale: .linearFloat(SIMD3(repeating: size)),
                                     rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
        }
        let w: Float = 5, d: Float = 4, h: Float = 2.5
        for _ in 0..<26_000 { // floor, boards
            let x = rnd() * w, z = rnd() * d
            add([x, 0, z], (Int(x * 2) + Int(z * 2)) % 2 == 0 ? [0.72, 0.55, 0.38] : [0.64, 0.48, 0.32], 0.035)
        }
        for _ in 0..<12_000 { add([rnd() * w, h, rnd() * d], [0.92, 0.92, 0.9], 0.05) } // ceiling
        for _ in 0..<9_000 { add([rnd() * w, rnd() * h, 0], [0.55, 0.7, 0.68], 0.04) }   // back wall
        for _ in 0..<9_000 { add([rnd() * w, rnd() * h, d], [0.86, 0.84, 0.78], 0.04) }
        for _ in 0..<7_000 { add([0, rnd() * h, rnd() * d], [0.86, 0.84, 0.78], 0.04) }
        for _ in 0..<7_000 { add([w, rnd() * h, rnd() * d], [0.86, 0.84, 0.78], 0.04) }
        for _ in 0..<6_000 { // table top
            add([1.8 + rnd() * 1.2, 0.75, 1.5 + rnd() * 0.8], [0.35, 0.22, 0.14], 0.025)
        }
        for _ in 0..<8_000 { // sofa, red, so up is obvious
            add([0.4 + rnd() * 2.0, 0.1 + rnd() * 0.8, 3.0 + rnd() * 0.8], [0.8, 0.2, 0.18], 0.03)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = try SplatPLYSceneWriter(toFileAtPath: url.path)
            try await writer.start(sphericalHarmonicDegree: 0, binary: true, pointCount: points.count)
            try await writer.write(points)
            try await writer.close()
        } catch {
            print("SplatDebugSample failed: \(error)")
        }
    }
}
#endif
