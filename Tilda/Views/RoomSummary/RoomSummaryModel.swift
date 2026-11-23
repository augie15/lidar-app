import Foundation

/// Derived numbers and formatting for the room summary. Everything is stored in metres / m²;
/// conversion goes through `Measurement`, rounding follows the display units.
struct RoomSummaryFormatter {
    var units: AppSettings.Units
    var imperial: Bool { units == .imperial }

    // MARK: Constants
    static let paintCoverageM2PerLitre: Float = 10
    static let paintCoats: Float = 2
    static let flooringWaste: Float = 0.10
    static let litresPerUSGallon = 3.785_411_784

    // MARK: Area
    private func sqft(_ m2: Float) -> Double {
        Measurement(value: Double(m2), unit: UnitArea.squareMeters).converted(to: .squareFeet).value
    }

    private static func number(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }

    var areaUnit: String { imperial ? "sq ft" : "m²" }
    var altAreaUnit: String { imperial ? "m²" : "sq ft" }

    /// Number only, in the display unit.
    func areaNumber(_ m2: Float) -> String {
        imperial ? Self.number(sqft(m2), digits: 0) : Self.number(Double(m2), digits: 1)
    }
    func area(_ m2: Float) -> String { "\(areaNumber(m2)) \(areaUnit)" }
    /// The other unit, for the small secondary line.
    func altArea(_ m2: Float) -> String {
        imperial ? "\(Self.number(Double(m2), digits: 1)) m²" : "\(Self.number(sqft(m2), digits: 0)) sq ft"
    }

    // MARK: Length
    func length(_ m: Float) -> String {
        if imperial {
            let feet = Measurement(value: Double(m), unit: UnitLength.meters).converted(to: .feet).value
            let totalInches = Int((feet * 12).rounded())
            return "\(totalInches / 12)′ \(totalInches % 12)″"
        }
        return "\(Self.number(Double(m), digits: 1)) m"
    }

    /// "6″" or "15 cm" for a wall thickness in metres (nil falls back to the current setting).
    func wallThickness(_ t: Float?) -> String {
        let metres = Double(t ?? AppSettings.wallThickness)
        if imperial { return "\(Int((metres * 39.3701).rounded()))″" }
        return "\(Int((metres * 100).rounded())) cm"
    }

    // MARK: Estimates
    func paintLitres(wallArea: Float) -> Double {
        Double(wallArea / Self.paintCoverageM2PerLitre * Self.paintCoats)
    }
    func paint(wallArea: Float) -> String {
        let l = paintLitres(wallArea: wallArea)
        let gal = Measurement(value: l, unit: UnitVolume.liters).converted(to: .gallons).value
        return "\(Self.number(l, digits: 1)) L · \(Self.number(gal, digits: 1)) gal"
    }
    func flooringArea(_ floor: Float) -> Float { floor * (1 + Self.flooringWaste) }

    /// Approximate length × width of a room from its area and perimeter, assuming a rectangle.
    /// nil when no rectangle has that area and perimeter.
    static func approxDimensions(area: Float, perimeter: Float) -> (long: Float, short: Float)? {
        guard area > 0, perimeter > 0 else { return nil }
        let s = perimeter / 2
        let disc = s * s - 4 * area
        guard disc >= 0 else { return nil }
        let r = disc.squareRoot()
        let short = (s - r) / 2
        guard short > 0.1 else { return nil }
        return ((s + r) / 2, short)
    }

    func dimensions(for room: RoomFacts.Room) -> String? {
        guard let d = Self.approxDimensions(area: room.floorArea, perimeter: room.perimeter) else { return nil }
        return "\(length(d.long)) × \(length(d.short))"
    }
}

extension RoomFacts {
    var averageCeiling: Float {
        let h = rooms.map(\.ceilingHeight).filter { $0 > 0 }
        return h.isEmpty ? 0 : h.reduce(0, +) / Float(h.count)
    }
    var totalDoors: Int { rooms.reduce(0) { $0 + $1.doorCount } }
    var totalWindows: Int { rooms.reduce(0) { $0 + $1.windowCount } }
}

extension RoomFacts.Room {
    var displayLabel: String { label.prefix(1).uppercased() + label.dropFirst() }

    /// Furniture grouped by category with counts, most numerous first.
    var furnitureGroups: [(name: String, count: Int)] {
        Dictionary(grouping: objects, by: { $0.category.lowercased() })
            .map { (name: $0.key.prefix(1).uppercased() + $0.key.dropFirst(), count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

enum RoomSummaryText {
    static func make(name: String, facts: RoomFacts, fixtures: FixtureLibrary? = nil,
                     units: AppSettings.Units) -> String {
        let f = RoomSummaryFormatter(units: units)
        var out = ["\(name) – room summary", ""]
        out.append("Total floor area: \(f.area(facts.totalFloorArea)) (\(f.altArea(facts.totalFloorArea)))")
        if let open = facts.totalOpenFloorArea {
            out.append("Open floor area (not covered by furniture): \(f.area(open)) (\(f.altArea(open)))")
        }
        if let gross = facts.totalGrossArea {
            out.append("Estimated gross area (assumes \(f.wallThickness(facts.wallThickness)) walls): \(f.area(gross)) (\(f.altArea(gross)))")
        }
        out.append("Rooms: \(facts.rooms.count)")
        out.append("Average ceiling height: \(f.length(facts.averageCeiling))")
        out.append("Doors: \(facts.totalDoors), windows: \(facts.totalWindows)")
        if let line = fixtures?.summaryLine(lengthText: { f.length($0) }) { out.append("Fixtures: \(line)") }
        for r in facts.rooms {
            out += ["", "\(r.displayLabel) – \(f.area(r.floorArea))"]
            if let d = f.dimensions(for: r) { out.append("  Approx. \(d)") }
            if let open = r.openFloorArea { out.append("  Open floor: \(f.area(open))") }
            if let gross = r.grossArea { out.append("  Gross (est.): \(f.area(gross))") }
            out.append("  Perimeter: \(f.length(r.perimeter))")
            out.append("  Ceiling height: \(f.length(r.ceilingHeight))")
            out.append("  Wall area: \(f.area(r.wallArea))")
            out.append("  Doors: \(r.doorCount), windows: \(r.windowCount), openings: \(r.openingCount)")
            let groups = r.furnitureGroups
            if !groups.isEmpty {
                out.append("  Furniture: " + groups.map { "\($0.name) × \($0.count)" }.joined(separator: ", "))
            }
            out.append("  Paint (2 coats): \(f.paint(wallArea: r.wallArea))")
            out.append("  Flooring (+10% waste): \(f.area(f.flooringArea(r.floorArea)))")
        }
        out += ["", "Measured with Tilda. Dimensions are approximate; estimates assume 10 m² per litre of paint and 10% flooring waste."]
        return out.joined(separator: "\n")
    }
}

// MARK: - Sample data (previews and simulator testing)

enum RoomSummarySample {
    static let facts = RoomFacts(rooms: [
        .init(label: "living room", floorArea: 28.4, perimeter: 22.6, ceilingHeight: 2.46, wallArea: 52.8,
              doorCount: 2, windowCount: 3, openingCount: 1,
              objects: [
                .init(category: "sofa", attributes: [], width: 2.1, depth: 0.9, height: 0.8),
                .init(category: "table", attributes: [], width: 1.2, depth: 0.6, height: 0.45),
                .init(category: "chair", attributes: [], width: 0.6, depth: 0.6, height: 0.9),
                .init(category: "chair", attributes: [], width: 0.6, depth: 0.6, height: 0.9),
                .init(category: "television", attributes: [], width: 1.2, depth: 0.1, height: 0.7),
                .init(category: "storage", attributes: [], width: 1.0, depth: 0.4, height: 1.8)]),
        .init(label: "kitchen", floorArea: 14.2, perimeter: 15.4, ceilingHeight: 2.46, wallArea: 31.9,
              doorCount: 1, windowCount: 1, openingCount: 1,
              objects: [
                .init(category: "refrigerator", attributes: [], width: 0.9, depth: 0.7, height: 1.8),
                .init(category: "stove", attributes: [], width: 0.76, depth: 0.65, height: 0.9),
                .init(category: "sink", attributes: [], width: 0.8, depth: 0.5, height: 0.9),
                .init(category: "dishwasher", attributes: [], width: 0.6, depth: 0.6, height: 0.85)]),
        .init(label: "Room 3", floorArea: 17.8, perimeter: 17.0, ceilingHeight: 2.43, wallArea: 38.4,
              doorCount: 1, windowCount: 2, openingCount: 0,
              objects: [
                .init(category: "bed", attributes: [], width: 1.6, depth: 2.0, height: 0.5),
                .init(category: "storage", attributes: [], width: 1.2, depth: 0.5, height: 1.0)])
    ])

    static var plan: FloorPlan {
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [FloorPlan.Segment] {
            [.init(start: [x0, y0], end: [x1, y0]), .init(start: [x1, y0], end: [x1, y1]),
             .init(start: [x1, y1], end: [x0, y1]), .init(start: [x0, y1], end: [x0, y0])]
        }
        var p = FloorPlan()
        p.walls = rect(0, 0, 7.5, 3.8) + rect(7.5, 0, 12.1, 3.1) + rect(0, 3.8, 4.76, 7.54)
        p.doors = [.init(start: [2.0, 3.8], end: [2.9, 3.8]), .init(start: [7.5, 1.0], end: [7.5, 1.9])]
        p.windows = [.init(start: [1.5, 0], end: [3.0, 0]), .init(start: [4.2, 0], end: [5.8, 0]), .init(start: [9, 0], end: [10.2, 0])]
        p.openings = [.init(start: [7.5, 2.2], end: [7.5, 3.0])]
        p.objects = [.init(center: [3.5, 2.8], size: [2.1, 0.9], rotation: 0, label: "sofa"),
                     .init(center: [2.4, 5.6], size: [1.6, 2.0], rotation: 0, label: "bed")]
        return p
    }
}
