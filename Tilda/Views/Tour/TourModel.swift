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
    /// Minimum spacing between spots, in metres.
    static let spotSpacing: Float = 0.8

    /// Greedy pass in capture order: keep a frame when it is at least `spotSpacing` from every spot kept so far.
    /// The first frame is always kept.
    static func spots(from manifest: FrameRecorder.Manifest, framesDir: URL) -> [PhotoSpot] {
        var kept: [PhotoSpot] = []
        for frame in manifest.frames {
            let t = frame.transform
            let pos = SIMD2<Float>(t.columns.3.x, t.columns.3.z)
            if kept.contains(where: { simd_distance($0.position, pos) < spotSpacing }) { continue }
            // Camera looks down its -Z axis.
            let fwd = SIMD2<Float>(-t.columns.2.x, -t.columns.2.z)
            let len = simd_length(fwd)
            kept.append(PhotoSpot(id: kept.count,
                                  imageURL: framesDir.appendingPathComponent(frame.file_path),
                                  position: pos,
                                  facing: len > 0.15 ? fwd / len : nil))
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
