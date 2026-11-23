import Foundation
import RoomPlan
import simd

/// Measures RoomPlan rooms into `RoomFacts`.
enum RoomFactsBuilder {
    /// - Parameter structureWalls: the merged `CapturedStructure`'s walls, used to classify shared and exterior
    ///   walls for the whole-scan gross area. When nil, all rooms' walls are used.
    static func build(from rooms: [CapturedRoom], structureWalls: [CapturedRoom.Surface]? = nil,
                      wallThickness: Float = AppSettings.wallThickness) -> RoomFacts {
        let labels = uniqueLabels(for: rooms)
        let measured = rooms.enumerated().map { measure($1, label: labels[$0], thickness: wallThickness) }
        let stories = Set(rooms.map(\.story)).count
        var facts = RoomFacts(rooms: measured, storyCount: max(1, stories))
        facts.wallThickness = wallThickness

        // Estimated gross area (listing-style, measured to the outside of the walls):
        //   single room:   floor + perimeter * t + 4 t^2
        //   several rooms: sum of floors + shared interior wall length * t + exterior wall length * t + 4 t^2
        // A wall is shared when another room's wall runs parallel (< 10 degrees), within about 0.5 m, and overlaps by
        // at least 30% of the shorter wall. Each pair counts once. The merged structure's walls are used when given
        // (each treated as its own room, so any two near-coincident walls pair), else every room's walls.
        let walls: [RoomAreaGeometry.Wall]
        if let structureWalls, !structureWalls.isEmpty {
            walls = structureWalls.enumerated().compactMap { wallSegment($1, room: $0) }
        } else {
            walls = rooms.enumerated().flatMap { index, room in room.walls.compactMap { wallSegment($0, room: index) } }
        }
        let floors = measured.reduce(Float(0)) { $0 + $1.floorArea }
        facts.totalGrossArea = RoomAreaGeometry.totalGrossArea(floors: floors, walls: walls, thickness: wallThickness)
        return facts
    }

    private static func wallSegment(_ wall: CapturedRoom.Surface, room: Int) -> RoomAreaGeometry.Wall? {
        let m = wall.transform
        let c = SIMD2<Float>(m.columns.3.x, m.columns.3.z)
        let half = SIMD2<Float>(m.columns.0.x, m.columns.0.z) * (wall.dimensions.x / 2)
        return RoomAreaGeometry.Wall(a: c - half, b: c + half, room: room)
    }

    /// Floor area of one room in square metres (see `floorArea`).
    static func floorArea(of room: CapturedRoom) -> Float { floorArea(room) }

    private static func measure(_ room: CapturedRoom, label: String, thickness: Float) -> RoomFacts.Room {
        let wallLengths = room.walls.reduce(Float(0)) { $0 + $1.dimensions.x }
        let gross = room.walls.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        let cutouts = (room.doors + room.windows).reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        let floor = floorArea(room)
        let perimeter = wallLengths
        return RoomFacts.Room(
            label: label,
            floorArea: floor,
            openFloorArea: openFloorArea(room, floorArea: floor),
            grossArea: RoomAreaGeometry.grossArea(floor: floor, perimeter: perimeter, thickness: thickness),
            perimeter: perimeter,
            ceilingHeight: room.walls.map(\.dimensions.y).max() ?? 0,
            wallArea: max(0, gross - cutouts),
            doorCount: room.doors.count,
            windowCount: room.windows.count,
            openingCount: room.openings.count,
            objects: room.objects.map { object in
                RoomFacts.Object(category: String(describing: object.category),
                                 attributes: object.attributes.map(describe),
                                 width: object.dimensions.x,
                                 depth: object.dimensions.z,
                                 height: object.dimensions.y)
            })
    }

    // MARK: Area

    /// Preferred: the sum of the floor surfaces' polygons. Fallback: the polygon traced by the wall loop.
    private static func floorArea(_ room: CapturedRoom) -> Float {
        let fromFloors = room.floors.reduce(Float(0)) { $0 + polygonArea3D($1.polygonCorners) }
        if fromFloors > 0.01 { return fromFloors }
        return wallLoopArea(room.walls)
    }

    // MARK: Open floor area

    /// Floor minus floor-standing furniture, in square metres. Rasterised at 3 cm in world x/z: the floor polygons
    /// (or the wall loop) are the mask, and each object's oriented footprint is subtracted, so overlaps count once.
    /// Objects whose underside is more than 0.25 m above the floor (wall-mounted TVs, shelves) are skipped; stairs
    /// always count as covered. The raster is scaled to the exact polygon area so grid error doesn't show.
    private static func openFloorArea(_ room: CapturedRoom, floorArea: Float) -> Float? {
        var polygons = floorPolygons(room)
        if polygons.isEmpty {
            let loop = wallLoop(room.walls)
            if loop.count >= 3 { polygons = [loop] }
        }
        guard !polygons.isEmpty, floorArea > 0.01 else { return nil }

        let floorY = floorHeight(room)
        let footprints: [RoomAreaGeometry.Footprint] = room.objects.compactMap { object in
            let m = object.transform
            let covers = object.category == .stairs
                || RoomAreaGeometry.touchesFloor(centerY: m.columns.3.y, height: object.dimensions.y, floorY: floorY)
            guard covers else { return nil }
            return RoomAreaGeometry.Footprint(transform: m, sizeX: object.dimensions.x, sizeZ: object.dimensions.z)
        }
        let raster = RoomAreaGeometry.rasterize(polygons: polygons, footprints: footprints, cell: 0.03)
        guard raster.floor > 0.01 else { return nil }
        return min(floorArea, floorArea * raster.open / raster.floor)
    }

    private static func floorHeight(_ room: CapturedRoom) -> Float {
        if let y = room.floors.map({ $0.transform.columns.3.y }).min() { return y }
        if let y = room.walls.map({ $0.transform.columns.3.y - $0.dimensions.y / 2 }).min() { return y }
        return 0
    }

    /// Floor polygons as world x/z. `polygonCorners` are in the floor surface's local space (transform them by the
    /// surface transform to get world), but that isn't guaranteed across OS versions, so both readings are tried and
    /// the one that lands inside the walls' bounding box wins. Local is preferred on a tie.
    private static func floorPolygons(_ room: CapturedRoom) -> [[SIMD2<Float>]] {
        let wallPoints = room.walls.flatMap { wall -> [SIMD2<Float>] in
            guard let s = wallSegment(wall, room: 0) else { return [] }
            return [s.a, s.b]
        }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in wallPoints { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let haveBox = !wallPoints.isEmpty
        func inside(_ pts: [SIMD2<Float>]) -> Int {
            guard haveBox else { return 0 }
            return pts.filter { $0.x >= lo.x - 0.5 && $0.x <= hi.x + 0.5 && $0.y >= lo.y - 0.5 && $0.y <= hi.y + 0.5 }.count
        }
        return room.floors.compactMap { floor in
            guard floor.polygonCorners.count >= 3 else { return nil }
            let asWorld = floor.polygonCorners.map { c -> SIMD2<Float> in
                let w = floor.transform * SIMD4<Float>(c, 1)
                return SIMD2(w.x, w.z)
            }
            let asGiven = floor.polygonCorners.map { SIMD2<Float>($0.x, $0.z) }
            return inside(asGiven) > inside(asWorld) ? asGiven : asWorld
        }
    }

    /// Planar polygon area in 3D (Newell's method), so it doesn't matter which space the corners are in.
    private static func polygonArea3D(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        var normal = SIMD3<Float>.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            normal += simd_cross(a, b)
        }
        return simd_length(normal) / 2
    }

    /// Chains the walls end to end (nearest free end each step) and applies the shoelace formula in x/z.
    private static func wallLoopArea(_ walls: [CapturedRoom.Surface]) -> Float {
        let polygon = wallLoop(walls)
        guard polygon.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// The wall loop as an x/z polygon (empty if there are fewer than three walls).
    private static func wallLoop(_ walls: [CapturedRoom.Surface]) -> [SIMD2<Float>] {
        guard walls.count >= 3 else { return [] }
        let ends: [(SIMD2<Float>, SIMD2<Float>)] = walls.map { wall in
            let m = wall.transform
            let c = SIMD2<Float>(m.columns.3.x, m.columns.3.z)
            let half = SIMD2<Float>(m.columns.0.x, m.columns.0.z) * (wall.dimensions.x / 2)
            return (c - half, c + half)
        }
        var remaining = Array(ends.dropFirst())
        var polygon = [ends[0].0]
        var tip = ends[0].1
        while !remaining.isEmpty {
            polygon.append(tip)
            var best = 0, flip = false, bestDist = Float.greatestFiniteMagnitude
            for (i, e) in remaining.enumerated() {
                let d0 = simd_distance(tip, e.0), d1 = simd_distance(tip, e.1)
                if d0 < bestDist { bestDist = d0; best = i; flip = false }
                if d1 < bestDist { bestDist = d1; best = i; flip = true }
            }
            let e = remaining.remove(at: best)
            tip = flip ? e.0 : e.1
        }
        return polygon
    }

    // MARK: Labels and attributes

    private static func uniqueLabels(for rooms: [CapturedRoom]) -> [String] {
        let raw: [String?] = rooms.map { room in
            var names: [String] = []
            for section in room.sections {
                guard let name = title(section.label), !names.contains(name) else { continue }
                names.append(name)
            }
            return names.isEmpty ? nil : names.joined(separator: " & ")
        }
        var seen: [String: Int] = [:]
        return raw.enumerated().map { index, name in
            guard let name else { return "Room \(index + 1)" }
            seen[name, default: 0] += 1
            return seen[name] == 1 ? name : "\(name) \(seen[name]!)"
        }
    }

    private static func title(_ label: CapturedRoom.Section.Label) -> String? {
        switch label {
        case .livingRoom: "Living room"
        case .bedroom: "Bedroom"
        case .bathroom: "Bathroom"
        case .kitchen: "Kitchen"
        case .diningRoom: "Dining room"
        case .unidentified: nil
        @unknown default: nil
        }
    }

    /// "chairType: stool" style.
    private static func describe(_ attribute: any CapturedRoomAttribute) -> String {
        var type = String(describing: Swift.type(of: attribute))
        if let first = type.first { type = first.lowercased() + type.dropFirst() }
        return "\(type): \(attribute.rawValue)"
    }
}
