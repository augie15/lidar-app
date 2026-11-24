import Foundation
import simd

/// Top-down 2D plan of a Room scan, saved as `floorplan.json` in the scan folder.
/// Coordinates are ARKit world space projected onto the floor: x = world x, y = world z (metres).
/// This is the same space as FrameRecorder camera positions, so photo spots line up with the plan.
struct FloorPlan: Codable, Sendable {
    struct Segment: Codable, Sendable, Equatable {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
    }

    /// An oriented rectangle (furniture footprint, etc.).
    struct Box: Codable, Sendable {
        var center: SIMD2<Float>
        var size: SIMD2<Float>      // width, depth
        var rotation: Float         // radians around the vertical axis
        var label: String
    }

    var walls: [Segment] = []
    var doors: [Segment] = []
    var windows: [Segment] = []
    var openings: [Segment] = []
    var objects: [Box] = []
    /// Floor height in world Y, so a walkthrough camera can sit at eye level above it.
    var floorY: Float = 0

    static let fileName = "floorplan.json"

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url)
    }

    static func load(from url: URL) -> FloorPlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FloorPlan.self, from: data)
    }

    /// Bounds of everything in the plan: (min, max).
    var bounds: (SIMD2<Float>, SIMD2<Float>) {
        var points = (walls + doors + windows + openings).flatMap { [$0.start, $0.end] }
        points += objects.map(\.center)
        guard let first = points.first else { return (.zero, .zero) }
        return points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }
}
