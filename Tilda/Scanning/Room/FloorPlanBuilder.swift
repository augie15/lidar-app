import Foundation
import RoomPlan
import simd

/// Builds a top-down `FloorPlan` from RoomPlan data: one room, several rooms, or a merged `CapturedStructure`.
/// Rooms captured in one continuous ARSession share a world space, so merging is just concatenation.
enum FloorPlanBuilder {
    static func build(from room: CapturedRoom) -> FloorPlan {
        build(from: [room])
    }

    /// One plan covering every room (used for a whole floor, and as the fallback when merging fails).
    static func build(from rooms: [CapturedRoom]) -> FloorPlan {
        build(walls: rooms.flatMap(\.walls), doors: rooms.flatMap(\.doors), windows: rooms.flatMap(\.windows),
              openings: rooms.flatMap(\.openings), floors: rooms.flatMap(\.floors), objects: rooms.flatMap(\.objects))
    }

    /// One plan from the merged structure, so it matches the exported model.
    static func build(from structure: CapturedStructure) -> FloorPlan {
        build(walls: structure.walls, doors: structure.doors, windows: structure.windows,
              openings: structure.openings, floors: structure.floors, objects: structure.objects)
    }

    private static func build(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface],
                              windows: [CapturedRoom.Surface], openings: [CapturedRoom.Surface],
                              floors: [CapturedRoom.Surface], objects: [CapturedRoom.Object]) -> FloorPlan {
        var plan = FloorPlan()
        plan.walls = walls.map(segment)
        plan.doors = doors.map(segment)
        plan.windows = windows.map(segment)
        plan.openings = openings.map(segment)
        plan.objects = objects.map { object in
            let m = object.transform
            let axis = SIMD2<Float>(m.columns.0.x, m.columns.0.z)
            return FloorPlan.Box(center: SIMD2(m.columns.3.x, m.columns.3.z),
                                 size: SIMD2(object.dimensions.x, object.dimensions.z),
                                 rotation: atan2(axis.y, axis.x),
                                 label: String(describing: object.category))
        }

        // Floor height: lowest floor surface or wall bottom (surfaces are centred on their transform).
        var lows: [Float] = walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }
        lows += floors.map { $0.transform.columns.3.y }
        plan.floorY = lows.min() ?? 0
        return plan
    }

    /// Centre ± half width along the surface's local x axis, projected to x/z.
    private static func segment(_ surface: CapturedRoom.Surface) -> FloorPlan.Segment {
        let m = surface.transform
        let centre = SIMD2<Float>(m.columns.3.x, m.columns.3.z)
        let axis = SIMD2<Float>(m.columns.0.x, m.columns.0.z)
        let half = axis * (surface.dimensions.x / 2)
        return FloorPlan.Segment(start: centre - half, end: centre + half)
    }
}
