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
        var floorArea: Float
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

    var totalFloorArea: Float { rooms.reduce(0) { $0 + $1.floorArea } }

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
