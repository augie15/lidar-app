import Foundation
import FoundationModels
import simd

// Tools the Ask session can call. Each returns exact numbers computed from the scan files, so the model never has to
// measure, convert or guess.

private func m(_ v: Double) -> String { MeasureFormat.length(v) }

@available(iOS 26.0, *)
struct RoomFactsTool: Tool {
    let measurements: ScanMeasurements
    let name = "roomFacts"
    let description = "Returns the measured facts for each room: floor area, perimeter, ceiling height, wall area, doors, windows, openings and objects. Also gives open floor area and estimated gross area when known. Open floor area is the floor not covered by floor-standing furniture (wall-mounted items excluded). Estimated gross area adds wall thickness to the floor area, like listing-style square footage that measures to the outside of the walls."

    @Generable
    struct Arguments {
        @Guide(description: "Optional room label to look up, such as \"kitchen\". Leave empty for all rooms.")
        var room: String?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rooms = measurements.roomFacts?.rooms, !rooms.isEmpty else {
            return "No per-room measurements were saved with this scan."
        }
        let filter = arguments.room?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let picked = filter.isEmpty ? rooms : rooms.filter { $0.label.lowercased().contains(filter) }
        guard !picked.isEmpty else { return "No room matches \"\(filter)\". Rooms: " + rooms.map(\.label).joined(separator: ", ") }
        var header = ""
        if filter.isEmpty, let facts = measurements.roomFacts {
            var totals: [String] = []
            if let a = facts.totalOpenFloorArea { totals.append("total open floor area \(MeasureFormat.area(Double(a)))") }
            if let g = facts.totalGrossArea {
                let t = facts.wallThickness.map { " assuming \(String(format: "%.0f", Double($0) * 100)) cm walls" } ?? ""
                totals.append("total estimated gross area \(MeasureFormat.area(Double(g)))\(t)")
            }
            if !totals.isEmpty { header = "Whole scan: " + totals.joined(separator: ", ") + ".\n" }
        }
        return header + picked.map { r in
            var extra = ""
            if let o = r.openFloorArea { extra += ", open floor (not covered by furniture) \(MeasureFormat.area(Double(o)))" }
            if let g = r.grossArea { extra += ", estimated gross (with wall thickness) \(MeasureFormat.area(Double(g)))" }
            return "\(r.label): floor \(MeasureFormat.area(Double(r.floorArea)))\(extra), perimeter \(m(Double(r.perimeter))), "
                + "ceiling \(m(Double(r.ceilingHeight))), wall area \(MeasureFormat.area(Double(r.wallArea))), "
                + "\(r.doorCount) doors, \(r.windowCount) windows, \(r.openingCount) openings, "
                + "\(r.objects.count) objects"
        }.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct WallLengthsTool: Tool {
    let measurements: ScanMeasurements
    let name = "wallLengths"
    let description = "Returns the length of every wall segment from the floor plan, plus door, window and opening widths."

    @Generable
    struct Arguments {
        @Guide(description: "Always pass true.")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        guard let plan = measurements.floorPlan, !plan.walls.isEmpty else { return "This scan has no floor plan." }
        func len(_ s: FloorPlan.Segment) -> Double { Double(simd_distance(s.start, s.end)) }
        let walls = plan.walls.enumerated().map { "Wall \($0.offset + 1): \(m(len($0.element)))" }
        let total = plan.walls.reduce(0.0) { $0 + len($1) }
        var lines = walls + ["Total wall length: \(m(total))"]
        if !plan.doors.isEmpty { lines.append("Doors: " + plan.doors.map { m(len($0)) }.joined(separator: ", ")) }
        if !plan.windows.isEmpty { lines.append("Windows: " + plan.windows.map { m(len($0)) }.joined(separator: ", ")) }
        if !plan.openings.isEmpty { lines.append("Openings: " + plan.openings.map { m(len($0)) }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct SurfaceAreasTool: Tool {
    let measurements: ScanMeasurements
    let name = "surfaceAreas"
    let description = "Returns the area of each classified surface (floor, wall, ceiling, table and so on) measured by the mesh scan."

    @Generable
    struct Arguments {
        @Guide(description: "Always pass true.")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        guard !measurements.surfaces.isEmpty else { return "No per-surface areas were saved with this scan." }
        return measurements.surfaces.map { "\($0.name): \(MeasureFormat.area($0.area))" }.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct ObjectDimensionsTool: Tool {
    let measurements: ScanMeasurements
    let name = "objectDimensions"
    let description = "Returns width, depth and height of objects in the scan, and the overall size of the model."

    @Generable
    struct Arguments {
        @Guide(description: "Optional object name to look up, such as \"sofa\". Leave empty for all objects.")
        var object: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var lines: [String] = []
        let filter = arguments.object?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let items = measurements.items.filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
        lines += items.map { "\($0.name): \(MeasureFormat.dimensions($0.width, $0.depth, $0.height)) (width x depth x height)" }
        if let e = measurements.modelExtent, filter.isEmpty {
            lines.append("Whole model: \(MeasureFormat.dimensions(Double(e.x), Double(e.z), Double(e.y))) (width x depth x height)")
        }
        return lines.isEmpty ? "No matching objects were measured." : lines.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct PaintEstimateTool: Tool {
    let measurements: ScanMeasurements
    let name = "paintEstimate"
    let description = "Estimates paint for the walls: wall area times coats divided by coverage per litre. Walls only, ceiling excluded."

    @Generable
    struct Arguments {
        @Guide(description: "Square metres one litre covers. Default 10.")
        var coveragePerLitre: Double?
        @Guide(description: "Number of coats. Default 2.")
        var coats: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let wall = measurements.wallArea, wall > 0 else {
            return "Wall area is not known for this scan, so no paint estimate can be made."
        }
        let coverage = max(1, arguments.coveragePerLitre ?? 10)
        let coats = max(1, arguments.coats ?? 2)
        let litres = wall * Double(coats) / coverage
        return String(format: "Wall area %@ (doors and windows excluded where known). %d coats at %.1f m² per litre: %.1f litres (%.1f US gallons). Buy a little extra for touch-ups.",
                      MeasureFormat.area(wall), coats, coverage, litres, litres * 0.264172)
    }
}

@available(iOS 26.0, *)
struct FitCheckTool: Tool {
    let measurements: ScanMeasurements
    let name = "fitCheck"
    let description = "Checks whether a piece of furniture of a given length could sit against a wall, using wall lengths and floor area. Does not know about furniture already in the room or door swings."

    @Generable
    struct Arguments {
        @Guide(description: "Length of the item in metres, for example 2 for a 2 m sofa.")
        var lengthMetres: Double
        @Guide(description: "Optional depth of the item in metres.")
        var depthMetres: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        let need = arguments.lengthMetres
        var lines = ["Item length: \(m(need))."]
        let walls = measurements.wallLengths
        if !walls.isEmpty {
            let fitting = walls.filter { $0 >= need }.count
            lines.append("Longest wall: \(m(walls.max() ?? 0)). \(fitting) of \(walls.count) wall segments are at least that long.")
        } else if let e = measurements.modelExtent {
            let longest = Double(max(e.x, e.z))
            lines.append("No floor plan. The model's longest horizontal extent is \(m(longest)).")
        }
        if let area = measurements.totalFloorArea, let d = arguments.depthMetres {
            lines.append("Item footprint \(String(format: "%.2f", need * d)) m² of \(MeasureFormat.area(area)) floor area.")
        }
        lines.append("This is a wall-length check only; furniture, doors and windows already in place are not considered.")
        return lines.joined(separator: "\n")
    }
}
