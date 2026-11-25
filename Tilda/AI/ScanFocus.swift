import Foundation

/// What the owner scans for. Shapes the on-device summary and the order of the facts in Insights.
/// Never changes a measurement: every number still comes from the facts.
enum ScanFocus: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, renovation, realEstate, interiorDesign, insurance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .renovation: "Renovation"
        case .realEstate: "Real estate"
        case .interiorDesign: "Interior design"
        case .insurance: "Home inventory"
        }
    }

    /// Short lower-case phrase for "For …" and "Rewrite for …".
    var phrase: String {
        switch self {
        case .general: "general use"
        case .renovation: "renovation"
        case .realEstate: "real estate"
        case .interiorDesign: "interior design"
        case .insurance: "home inventory"
        }
    }

    var detail: String {
        switch self {
        case .general: "A plain summary of whatever you scan"
        case .renovation: "Wall and floor areas, ceiling height, doors and windows"
        case .realEstate: "Floor area, rooms and light, in a factual listing tone"
        case .interiorDesign: "Open floor, dimensions, layout and furniture"
        case .insurance: "What is in the room, for insurance and records"
        }
    }

    var symbol: String {
        switch self {
        case .general: "square.grid.2x2"
        case .renovation: "hammer"
        case .realEstate: "house"
        case .interiorDesign: "chair.lounge"
        case .insurance: "shield.lefthalf.filled"
        }
    }

    /// Extra guidance appended to the model instructions. Empty for General.
    var guidance: String {
        switch self {
        case .general:
            ""
        case .renovation:
            "The reader is planning a renovation. Mention the wall area and floor area (useful for paint and flooring), "
            + "the ceiling height, and the doors and windows. Mention heaters or vents only if they are listed in the facts."
        case .realEstate:
            "The reader is preparing a property listing. Give the floor area in the units shown in the facts, the room type "
            + "if a room label is given, the ceiling height, and the windows and light if listed. "
            + "Use a factual listing tone with no sales hype, no adjectives like spacious or stunning."
        case .interiorDesign:
            "The reader is planning an interior design. Mention the open floor area, the room dimensions, the layout, "
            + "the existing furniture and the windows, as far as they appear in the facts."
        case .insurance:
            "The reader is keeping a home inventory for insurance. List the objects and furniture that are visible, "
            + "taken from the facts, image tags and text, plus the room type. Use a factual inventory tone."
        }
    }

    /// Fact labels that matter most for this focus, in order. Facts not listed keep their order after these.
    private var priorityLabels: [String] {
        switch self {
        case .general: []
        case .renovation: ["Wall area", "Floor area", "Open floor area", "Ceiling height", "Doors", "Windows", "Openings",
                           "Est. gross area", "Rooms"]
        case .realEstate: ["Floor area", "Rooms", "Ceiling height", "Windows", "Doors", "Open floor area", "Est. gross area"]
        case .interiorDesign: ["Open floor area", "Floor area", "Overall extent", "Objects", "Windows", "Ceiling height"]
        case .insurance: ["Objects", "Rooms", "Floor area"]
        }
    }

    /// Reorders facts for this focus. Nothing is removed.
    func ordered(_ facts: [ScanInsights.Fact]) -> [ScanInsights.Fact] {
        let order = priorityLabels
        guard !order.isEmpty else { return facts }
        let ranked = facts.enumerated().map { (index: $0.offset, rank: order.firstIndex(of: $0.element.label) ?? order.count,
                                               fact: $0.element) }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.fact)
    }
}
