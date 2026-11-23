import CoreGraphics
import Foundation
import ImageIO
import simd

/// One recorded camera photo, with its pose and intrinsics at the photo's full resolution.
struct ColorKeyframe: Sendable {
    var imageURL: URL
    var cameraToWorld: simd_float4x4
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Int, height: Int
}

/// Per-vertex color from camera keyframes.
///
/// Streams one keyframe at a time (downsampled to `sampleWidth`) over all vertices, so memory stays at one small
/// image plus a few bytes per vertex. For each vertex the best keyframe wins: the vertex must project inside the
/// image and in front of the camera; frames that see the surface head-on and from close up beat oblique, distant ones.
/// There is no occlusion test, so a surface hidden behind a wall can pick up the wall's color if the wall's normal
/// does not already reject it (back-facing frames are only used when nothing faces the vertex).
enum MeshColorizer {
    static let sampleWidth = 640
    static let maxDistance: Float = 6
    static let unseen = SIMD3<Float>(repeating: 0.5)

    /// `positions` / `normals`: packed float3 world-space arrays, one entry per chunk. Returns one packed float4 (RGBA)
    /// `Data` per chunk, in the same order.
    static func colorize(positions: [Data], normals: [Data], keyframes: [ColorKeyframe]) -> [Data] {
        let counts = positions.map { $0.count / 12 }
        let total = counts.reduce(0, +)
        guard total > 0 else { return counts.map { _ in Data() } }

        var pos = [Float](repeating: 0, count: total * 3)
        var nor = [Float](repeating: 0, count: total * 3)
        var offset = 0
        for (i, n) in counts.enumerated() {
            positions[i].withUnsafeBytes { src in
                pos.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.advanced(by: offset * 12).copyMemory(from: src.baseAddress!, byteCount: n * 12)
                }
            }
            normals[i].withUnsafeBytes { src in
                nor.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.advanced(by: offset * 12).copyMemory(from: src.baseAddress!, byteCount: min(n * 12, src.count))
                }
            }
            offset += n
        }

        var best = [Float](repeating: -1, count: total)
        var rgb = [UInt8](repeating: 128, count: total * 3)

        for frame in keyframes {
            autoreleasepool {
                guard let image = decode(frame.imageURL, maxWidth: sampleWidth) else { return }
                apply(frame: frame, image: image, pos: pos, nor: nor, best: &best, rgb: &rgb)
            }
        }

        var out: [Data] = []
        offset = 0
        for n in counts {
            var colors = [Float](repeating: 1, count: n * 4)
            for i in 0..<n {
                let g = offset + i
                if best[g] < 0 {
                    colors[i * 4] = unseen.x; colors[i * 4 + 1] = unseen.y; colors[i * 4 + 2] = unseen.z
                } else {
                    colors[i * 4] = Float(rgb[g * 3]) / 255
                    colors[i * 4 + 1] = Float(rgb[g * 3 + 1]) / 255
                    colors[i * 4 + 2] = Float(rgb[g * 3 + 2]) / 255
                }
            }
            out.append(colors.withUnsafeBufferPointer { Data(buffer: $0) })
            offset += n
        }
        return out
    }

    struct SampledImage {
        var pixels: [UInt8]   // RGBA8
        var width: Int
        var height: Int
    }

    static func decode(_ url: URL, maxWidth: Int) -> SampledImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? SampledImage(pixels: pixels, width: w, height: h) : nil
    }

    private static func apply(frame: ColorKeyframe, image: SampledImage, pos: [Float], nor: [Float],
                              best: inout [Float], rgb: inout [UInt8]) {
        // Scale intrinsics from the full-resolution photo to the downsampled image.
        let sx = Float(image.width) / Float(frame.width)
        let sy = Float(image.height) / Float(frame.height)
        let proj = CameraProjection(cameraToWorld: frame.cameraToWorld,
                                    fx: frame.fx * sx, fy: frame.fy * sy, cx: frame.cx * sx, cy: frame.cy * sy,
                                    width: Float(image.width), height: Float(image.height))
        let eye = proj.cameraPosition
        let total = pos.count / 3
        let w = image.width, h = image.height
        let maxD = maxDistance
        let blockSize = 16384
        let blocks = (total + blockSize - 1) / blockSize

        pos.withUnsafeBufferPointer { P in
            nor.withUnsafeBufferPointer { N in
                best.withUnsafeMutableBufferPointer { B in
                    rgb.withUnsafeMutableBufferPointer { C in
                        image.pixels.withUnsafeBufferPointer { px in
                            let Bp = B.baseAddress!, Cp = C.baseAddress!
                            DispatchQueue.concurrentPerform(iterations: blocks) { block in
                                let start = block * blockSize
                                let end = min(start + blockSize, total)
                                for i in start..<end {
                                    let p = SIMD3<Float>(P[i * 3], P[i * 3 + 1], P[i * 3 + 2])
                                    guard let hit = proj.project(p), hit.depth < maxD else { continue }
                                    guard hit.u >= 0, hit.v >= 0, hit.u <= Float(w - 1), hit.v <= Float(h - 1) else { continue }
                                    let toEye = eye - p
                                    let dist = simd_length(toEye)
                                    let n = SIMD3<Float>(N[i * 3], N[i * 3 + 1], N[i * 3 + 2])
                                    let facing = simd_dot(n, toEye) / max(dist, 1e-4)
                                    // Head-on frames form the top tier; within a tier, closer and more head-on wins.
                                    let score: Float = facing > 0.1
                                        ? 2 + facing / (1 + dist)
                                        : 0.01 / (1 + dist)
                                    guard score > Bp[i] else { continue }
                                    Bp[i] = score
                                    // Bilinear sample.
                                    let x0 = Int(hit.u), y0 = Int(hit.v)
                                    let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                                    let fx = hit.u - Float(x0), fy = hit.v - Float(y0)
                                    for c in 0..<3 {
                                        let a = Float(px[(y0 * w + x0) * 4 + c]), b = Float(px[(y0 * w + x1) * 4 + c])
                                        let d = Float(px[(y1 * w + x0) * 4 + c]), e = Float(px[(y1 * w + x1) * 4 + c])
                                        let top = a + (b - a) * fx, bot = d + (e - d) * fx
                                        Cp[i * 3 + c] = UInt8(max(0, min(255, top + (bot - top) * fy)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
