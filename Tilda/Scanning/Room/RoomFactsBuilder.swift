import Foundation
import RoomPlan
import simd

/// Measures RoomPlan rooms into `RoomFacts`.
enum RoomFactsBuilder {
    static func build(from rooms: [CapturedRoom]) -> RoomFacts {
        let labels = uniqueLabels(for: rooms)
        let measured = rooms.enumerated().map { measure($1, label: labels[$0]) }
        let stories = Set(rooms.map(\.story)).count
        return RoomFacts(rooms: measured, storyCount: max(1, stories))
    }

    /// Floor area of one room in square metres (see `floorArea`).
    static func floorArea(of room: CapturedRoom) -> Float { floorArea(room) }

    private static func measure(_ room: CapturedRoom, label: String) -> RoomFacts.Room {
        let wallLengths = room.walls.reduce(Float(0)) { $0 + $1.dimensions.x }
        let gross = room.walls.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        let cutouts = (room.doors + room.windows).reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        return RoomFacts.Room(
            label: label,
            floorArea: floorArea(room),
            perimeter: wallLengths,
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
        guard walls.count >= 3 else { return 0 }
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
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
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
