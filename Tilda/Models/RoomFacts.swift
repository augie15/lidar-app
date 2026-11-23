import Foundation

/// Measured facts about a Room scan (one room or a merged floor), saved as `roomfacts.json` in the scan folder.
/// Written by the Room capture flow from RoomPlan data; read by the AI features and the detail screen.
/// All lengths in metres, areas in square metres.
struct RoomFacts: Codable, Sendable {
    struct Object: Codable, Sendable {
        var category: String            // e.g. "sofa", "table", "bed"
        var attributes: [String]        // RoomPlan attributes, e.g. "chairType: stool" (may be empty)
        var width: Float
        var depth: Float
        var height: Float
    }

    struct Room: Codable, Sendable {
        var label: String               // RoomPlan section label ("living room", "kitchen"…) or "Room 1"
        /// Net interior floor area (inside face of the walls). Furniture does not reduce it.
        var floorArea: Float
        /// Floor area not covered by floor-standing furniture footprints (union of footprints, clipped to the
        /// room). Wall-mounted or raised items are excluded. Nil for scans made before this existed.
        var openFloorArea: Float? = nil
        /// Estimated gross area: floor area plus this room's share of wall thickness (half of each wall's
        /// thickness all round). Nil for older scans.
        var grossArea: Float? = nil
        var perimeter: Float
        var ceilingHeight: Float
        var wallArea: Float             // total wall surface, minus doors and windows
        var doorCount: Int
        var windowCount: Int
        var openingCount: Int
        var objects: [Object]
    }

    var rooms: [Room]
    var storyCount: Int = 1
    /// Wall thickness assumed for gross area, in metres.
    var wallThickness: Float? = nil
    /// Estimated gross area of the whole scan: interior floor plus all wall thickness, counting shared interior
    /// walls once and exterior walls in full (comparable to listing-style square footage). Nil for older scans.
    var totalGrossArea: Float? = nil

    var totalFloorArea: Float { rooms.reduce(0) { $0 + $1.floorArea } }
    /// Sum of open floor area, or nil if any room lacks it.
    var totalOpenFloorArea: Float? {
        let values = rooms.compactMap(\.openFloorArea)
        return values.count == rooms.count && !values.isEmpty ? values.reduce(0, +) : nil
    }

    static let fileName = "roomfacts.json"

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    static func load(from url: URL) -> RoomFacts? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RoomFacts.self, from: data)
    }
}
