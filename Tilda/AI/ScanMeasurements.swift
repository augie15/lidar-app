import Foundation
import ModelIO
import simd

/// Everything measurable about a scan, loaded from the scan folder. Used for the Insights facts and by the Ask tools,
/// so the model is only ever handed exact numbers computed here.
struct ScanMeasurements: Sendable {
    struct Surface: Sendable { var name: String; var area: Double }   // m²
    struct Item: Sendable { var name: String; var width: Double; var depth: Double; var height: Double? } // metres

    var roomFacts: RoomFacts?
    var floorPlan: FloorPlan?
    var surfaces: [Surface] = []
    /// Axis-aligned extent of the model in metres: x, y (up), z.
    var modelExtent: SIMD3<Float>?

    static func load(folder: URL, modelURL: URL) async -> ScanMeasurements {
        var m = ScanMeasurements()
        m.roomFacts = RoomFacts.load(from: folder.appendingPathComponent(RoomFacts.fileName))
        m.floorPlan = FloorPlan.load(from: folder.appendingPathComponent(FloorPlan.fileName))
        m.surfaces = loadSurfaces(folder.appendingPathComponent("surfaces.json"))
        m.modelExtent = await Task.detached(priority: .utility) { modelExtent(of: modelURL) }.value
        return m
    }

    // MARK: Loading

    /// `surfaces.json` is written by the mesh scanner; accept the shapes it could plausibly take:
    /// {"floor": 12.3}, {"surfaces": {...}}, [{"name"/"class"/"label": "floor", "area": 12.3}].
    static func loadSurfaces(_ url: URL) -> [Surface] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        func parse(_ any: Any) -> [Surface] {
            if let dict = any as? [String: Any] {
                if let a = number(dict["area"] ?? dict["areaM2"] ?? dict["area_m2"]),
                   let name = (dict["name"] ?? dict["class"] ?? dict["label"] ?? dict["classification"]) as? String {
                    return [Surface(name: name, area: a)]
                }
                var out: [Surface] = []
                for (key, value) in dict {
                    if let a = number(value) { out.append(Surface(name: key, area: a)) } else { out += parse(value) }
                }
                return out
            }
            if let array = any as? [Any] { return array.flatMap(parse) }
            return []
        }
        return parse(json).filter { $0.area > 0 }.sorted { $0.area > $1.area }
    }

    static func modelExtent(of url: URL) -> SIMD3<Float>? {
        let asset = MDLAsset(url: url)
        let box = asset.boundingBox
        let e = box.maxBounds - box.minBounds
        guard e.x.isFinite, e.y.isFinite, e.z.isFinite, e.x > 0 || e.y > 0 || e.z > 0 else { return nil }
        return e
    }

    // MARK: Derived numbers

    var hasAnyData: Bool { roomFacts != nil || floorPlan != nil || !surfaces.isEmpty || modelExtent != nil }

    var totalFloorArea: Double? {
        if let f = roomFacts, f.totalFloorArea > 0 { return Double(f.totalFloorArea) }
        return surfaces.first { $0.name.lowercased().contains("floor") }?.area
    }

    var ceilingHeight: Double? {
        guard let rooms = roomFacts?.rooms, !rooms.isEmpty else { return nil }
        let hs = rooms.map { Double($0.ceilingHeight) }.filter { $0 > 0 }
        return hs.isEmpty ? nil : hs.max()
    }

    /// Wall surface in m², minus doors and windows when known.
    var wallArea: Double? {
        if let f = roomFacts, f.rooms.reduce(0, { $0 + $1.wallArea }) > 0 {
            return Double(f.rooms.reduce(0) { $0 + $1.wallArea })
        }
        if let a = surfaces.first(where: { $0.name.lowercased().contains("wall") })?.area { return a }
        if let plan = floorPlan, let h = ceilingHeight {
            let perimeter = plan.walls.reduce(0.0) { $0 + Double(simd_distance($1.start, $1.end)) }
            let cut = (plan.doors + plan.windows + plan.openings).reduce(0.0) { $0 + Double(simd_distance($1.start, $1.end)) }
            return max(0, (perimeter - cut) * h)
        }
        return nil
    }

    var wallLengths: [Double] {
        (floorPlan?.walls ?? []).map { Double(simd_distance($0.start, $0.end)) }
    }

    var doorCount: Int? { roomFacts.map { $0.rooms.reduce(0) { $0 + $1.doorCount } } ?? floorPlan.map { $0.doors.count } }
    var windowCount: Int? { roomFacts.map { $0.rooms.reduce(0) { $0 + $1.windowCount } } ?? floorPlan.map { $0.windows.count } }

    var items: [Item] {
        if let f = roomFacts {
            return f.rooms.flatMap { $0.objects }.map {
                Item(name: $0.category, width: Double($0.width), depth: Double($0.depth), height: Double($0.height))
            }
        }
        return (floorPlan?.objects ?? []).map {
            Item(name: $0.label, width: Double($0.size.x), depth: Double($0.size.y), height: nil)
        }
    }
}

// MARK: - Formatting (units follow AppSettings.units, chosen unit first)

enum MeasureFormat {
    static func area(_ m2: Double) -> String {
        let ft2 = m2 * 10.7639
        let metric = "\(number(m2)) m²", imperial = "\(number(ft2, forceInt: true)) ft²"
        return AppSettings.units == .imperial ? "\(imperial) · \(metric)" : "\(metric) · \(imperial)"
    }

    static func length(_ m: Double) -> String {
        let metric = String(format: "%.2f m", m)
        let totalInches = Int((m * 39.3701).rounded())
        let imperial = totalInches >= 12 ? "\(totalInches / 12) ft \(totalInches % 12) in" : "\(totalInches) in"
        return AppSettings.units == .imperial ? "\(imperial) · \(metric)" : "\(metric) · \(imperial)"
    }

    static func dimensions(_ w: Double, _ d: Double, _ h: Double?) -> String {
        let parts = [w, d] + (h.map { [$0] } ?? [])
        let metric = parts.map { String(format: "%.2f", $0) }.joined(separator: " × ") + " m"
        let imperial = parts.map { String(format: "%.1f", $0 * 3.28084) }.joined(separator: " × ") + " ft"
        return AppSettings.units == .imperial ? "\(imperial) · \(metric)" : "\(metric) · \(imperial)"
    }

    private static func number(_ v: Double, forceInt: Bool = false) -> String {
        forceInt || v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}

// MARK: - Deterministic facts

extension ScanMeasurements {
    func facts(kind: ScanKind) -> [ScanInsights.Fact] {
        var out: [ScanInsights.Fact] = []
        func add(_ l: String, _ v: String) { out.append(.init(label: l, value: v)) }

        if let a = totalFloorArea { add("Floor area", MeasureFormat.area(a)) }
        if let h = ceilingHeight { add("Ceiling height", MeasureFormat.length(h)) }
        if let rooms = roomFacts?.rooms, !rooms.isEmpty {
            add("Rooms", String(rooms.count))
        }
        if let w = wallArea, kind != .object { add("Wall area", MeasureFormat.area(w)) }
        if let d = doorCount, d > 0 { add("Doors", String(d)) }
        if let w = windowCount, w > 0 { add("Windows", String(w)) }
        if let o = roomFacts?.rooms.reduce(0, { $0 + $1.openingCount }) ?? floorPlan?.openings.count, o > 0 {
            add("Openings", String(o))
        }

        let all = items
        if !all.isEmpty {
            let counts = Dictionary(grouping: all, by: { $0.name.lowercased() }).mapValues(\.count)
            let summary = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(6).map { $0.value > 1 ? "\($0.value) \($0.key)" : $0.key }.joined(separator: ", ")
            add("Objects", "\(all.count): \(summary)")
            for item in all.sorted(by: { $0.width * $0.depth > $1.width * $1.depth }).prefix(4) {
                add(item.name.capitalized, MeasureFormat.dimensions(item.width, item.depth, item.height))
            }
        }

        if kind == .mesh || kind == .room, !surfaces.isEmpty, roomFacts == nil {
            for s in surfaces.prefix(5) { add(s.name.capitalized, MeasureFormat.area(s.area)) }
        }
        if let e = modelExtent {
            switch kind {
            case .object: add("Size (W × D × H)", MeasureFormat.dimensions(Double(e.x), Double(e.z), Double(e.y)))
            default: add("Overall extent", MeasureFormat.dimensions(Double(e.x), Double(e.z), Double(e.y)))
            }
        }
        return out
    }
}
