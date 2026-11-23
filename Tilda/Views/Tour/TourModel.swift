import ImageIO
import SwiftUI
import simd

/// One photo spot: a keyframe chosen so spots are spread through the room.
struct PhotoSpot: Identifiable, Sendable {
    let id: Int                    // index in capture order
    let imageURL: URL
    let position: SIMD2<Float>     // world x, z (same space as FloorPlan)
    let facing: SIMD2<Float>?      // unit vector of the camera's -Z on x/z, nil when looking straight up/down
}

enum TourModel {
    /// Spots closer than this are "the same place", in metres.
    static let spotSpacing: Float = 0.8
    /// Within the same place, a new view is kept when it faces at least this far from every view kept there.
    static let minViewAngleDegrees: Float = 35

    /// Greedy pass in capture order. A frame is skipped only when an already-kept spot is both nearby
    /// (< `spotSpacing`) and facing a similar direction (< `minViewAngleDegrees`). So walking through the room adds
    /// spots by distance, and turning on the spot (how RoomPlan coaches you to scan) adds one view per ~35°.
    /// Frames pointing straight up or down have no facing and only count as new when far from every spot.
    /// The first frame is always kept.
    static func spots(from manifest: FrameRecorder.Manifest, framesDir: URL) -> [PhotoSpot] {
        let minCos = cos(minViewAngleDegrees * .pi / 180)
        var kept: [PhotoSpot] = []
        for frame in manifest.frames {
            let t = frame.transform
            let pos = SIMD2<Float>(t.columns.3.x, t.columns.3.z)
            // Camera looks down its -Z axis.
            let fwd = SIMD2<Float>(-t.columns.2.x, -t.columns.2.z)
            let len = simd_length(fwd)
            let facing: SIMD2<Float>? = len > 0.15 ? fwd / len : nil

            let redundant = kept.contains { spot in
                guard simd_distance(spot.position, pos) < spotSpacing else { return false }
                guard let a = spot.facing, let b = facing else { return true }
                return simd_dot(a, b) > minCos
            }
            if redundant { continue }
            kept.append(PhotoSpot(id: kept.count,
                                  imageURL: framesDir.appendingPathComponent(frame.file_path),
                                  position: pos,
                                  facing: facing))
        }
        return kept
    }
}

/// Loads downsampled, portrait-oriented photos with ImageIO so full-size JPEGs never sit in memory.
enum TourImageLoader {
    static func load(_ url: URL, maxPixel: Int = 1400) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            // Frames are sensor landscape; .right displays them rotated 90° clockwise (portrait).
            return UIImage(cgImage: cg, scale: 1, orientation: .right)
        }.value
    }
}
