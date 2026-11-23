import Foundation
import simd

/// Pure geometry for turning "the model saw a vent in this photo" into a point in the room: undo the photo rotation,
/// cast a camera ray, intersect it with the floor, ceiling or a wall, then merge repeat sightings.
/// No UI, no model, no file access, so it can be checked on its own (see `selfCheck`).
///
/// Conventions: world space is ARKit's (metres, +Y up). Plan space is (x, z). The camera looks down its -Z axis with +Y
/// up and +X right, and the saved JPEG is the landscape sensor image (pixel y grows downward).
enum FixturePlacement {
    /// Rays that travel farther than this before hitting anything are thrown away.
    static let maxDistance: Float = 8
    /// Sightings of the same kind closer than this are one fixture.
    static let mergeRadius: Float = 0.6
    /// A lone sighting needs at least this confidence to survive; a fixture seen in two photos may be fainter.
    static let minSingleConfidence: Float = 0.7
    static let defaultCeilingHeight: Float = 2.4

    // MARK: Inputs

    struct Camera: Sendable {
        var transform: simd_float4x4        // camera to world
        var fx: Float, fy: Float, cx: Float, cy: Float
        var width: Float, height: Float     // sensor pixels, landscape
    }

    struct Room: Sendable {
        var floorY: Float
        var ceilingY: Float
        var walls: [FloorPlan.Segment]
    }

    /// Which way the sensor image was turned so that world-up is at the top, i.e. what the model was shown.
    enum Orientation: Sendable { case up, right, down, left }

    struct Ray: Sendable { var origin: SIMD3<Float>; var direction: SIMD3<Float> }

    struct Hit: Sendable {
        var point: SIMD3<Float>
        var distance: Float
        var wallAxis: SIMD2<Float>?
    }

    struct Placed: Sendable {
        var surface: Fixture.Surface
        var position: SIMD3<Float>
        var axis: SIMD2<Float>?
        var length: Float?
        var distance: Float
    }

    /// One detection in one photo, already placed in the room.
    struct Sighting: Sendable {
        var kind: Fixture.Kind
        var placed: Placed
        var confidence: Float
        var photoFrame: String
        var photoBox: NormalizedBox
    }

    // MARK: Photo orientation

    /// The turn that puts world-up at the top of the photo. Phones held upright give `.right`, the same turn the
    /// photo tour uses.
    static func orientation(for transform: simd_float4x4) -> Orientation {
        // World up expressed in camera axes (R^T * up): x = camera right, y = camera up.
        let up = SIMD3<Float>(transform.columns.0.y, transform.columns.1.y, transform.columns.2.y)
        if abs(up.x) > abs(up.y) { return up.x < 0 ? .right : .left }
        return up.y >= 0 ? .up : .down
    }

    /// A point in the upright photo (fractions, origin top-left) to a sensor pixel.
    static func sensorPixel(u: Float, v: Float, orientation: Orientation, width W: Float, height H: Float) -> SIMD2<Float> {
        switch orientation {
        case .up: SIMD2(u * W, v * H)
        case .down: SIMD2((1 - u) * W, (1 - v) * H)
        case .right: SIMD2(v * W, (1 - u) * H)          // upright = sensor turned 90 degrees clockwise
        case .left: SIMD2((1 - v) * W, u * H)           // upright = sensor turned 90 degrees counter-clockwise
        }
    }

    /// A box in the upright photo to a box in sensor fractions (the box's corners are mapped and re-fitted).
    static func sensorBox(uprightX x: Float, y: Float, width w: Float, height h: Float,
                          orientation: Orientation) -> NormalizedBox {
        let corners = [(x, y), (x + w, y), (x, y + h), (x + w, y + h)].map {
            sensorPixel(u: $0.0, v: $0.1, orientation: orientation, width: 1, height: 1)
        }
        let lo = corners.reduce(corners[0], simd_min), hi = corners.reduce(corners[0], simd_max)
        return NormalizedBox(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    // MARK: Rays and planes

    static func ray(camera: Camera, sensorPixel p: SIMD2<Float>) -> Ray {
        let local = SIMD3<Float>((p.x - camera.cx) / camera.fx, -(p.y - camera.cy) / camera.fy, -1)
        let t = camera.transform
        let world = t.columns.0 * local.x + t.columns.1 * local.y + t.columns.2 * local.z
        return Ray(origin: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                   direction: simd_normalize(SIMD3(world.x, world.y, world.z)))
    }

    /// Hit on the horizontal plane `y = height`, or nil when the ray is parallel to it or points away.
    static func horizontalPlane(_ ray: Ray, y height: Float) -> Hit? {
        guard abs(ray.direction.y) > 1e-5 else { return nil }
        let t = (height - ray.origin.y) / ray.direction.y
        guard t > 0 else { return nil }
        return Hit(point: ray.origin + ray.direction * t, distance: t, wallAxis: nil)
    }

    /// Hit on the vertical plane through a wall segment. `slack` is how far past either end of the segment still
    /// counts (metres).
    static func wall(_ ray: Ray, _ segment: FloorPlan.Segment, slack: Float, room: Room) -> Hit? {
        let o = SIMD2(ray.origin.x, ray.origin.z), d = SIMD2(ray.direction.x, ray.direction.z)
        let e = segment.end - segment.start
        let length = simd_length(e)
        guard length > 1e-3 else { return nil }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let denom = cross(d, e)
        guard abs(denom) > 1e-6 else { return nil }
        let diff = segment.start - o
        let t = cross(diff, e) / denom       // ray parameter (3D distance, direction is unit length)
        let s = cross(diff, d) / denom       // 0...1 along the segment
        guard t > 0, s * length >= -slack, s * length <= length + slack else { return nil }
        let p = ray.origin + ray.direction * t
        guard p.y >= room.floorY - 0.1, p.y <= room.ceilingY + 0.1 else { return nil }
        return Hit(point: p, distance: t, wallAxis: e / length)
    }

    static func nearestWall(_ ray: Ray, room: Room, slack: Float = 0.15) -> Hit? {
        room.walls.compactMap { wall(ray, $0, slack: slack, room: room) }.min { $0.distance < $1.distance }
    }

    // MARK: Placing one detection

    /// Where a detection sits in the room, or nil when the ray finds nothing within `maxDistance`.
    /// `box` is in the upright photo (fractions, origin top-left).
    static func place(kind: Fixture.Kind, surface claimed: Fixture.Surface, box: NormalizedBox,
                      orientation: Orientation, camera: Camera, room: Room) -> Placed? {
        // A baseboard heater is a wall unit by definition, whatever the model said.
        let surface: Fixture.Surface = kind == .baseboardHeater ? .wall : claimed
        func ray(atU u: Float, v: Float) -> Ray {
            self.ray(camera: camera, sensorPixel: sensorPixel(u: u, v: v, orientation: orientation,
                                                              width: camera.width, height: camera.height))
        }
        let centreU = box.x + box.width / 2, centreV = box.y + box.height / 2
        let centre = ray(atU: centreU, v: centreV)
        let wallHit = nearestWall(centre, room: room)

        switch surface {
        case .floor, .ceiling:
            let planeY = surface == .floor ? room.floorY : room.ceilingY
            guard let hit = horizontalPlane(centre, y: planeY), hit.distance <= maxDistance else { return nil }
            // Landing beyond the nearest wall means the ray left the room first: the plane hit is not real.
            if let wallHit, wallHit.distance < hit.distance - 0.25 { return nil }
            return Placed(surface: surface, position: hit.point, axis: nil, length: nil, distance: hit.distance)

        case .wall:
            if let wallHit, wallHit.distance <= maxDistance {
                var placed = Placed(surface: .wall, position: wallHit.point, axis: wallHit.wallAxis,
                                    length: nil, distance: wallHit.distance)
                if kind == .baseboardHeater, let axis = wallHit.wallAxis,
                   let segment = room.walls.first(where: { seg in
                       let e = seg.end - seg.start
                       let l = simd_length(e)
                       return l > 1e-3 && simd_length(e / l - axis) < 1e-4
                   }) {
                    // Length: where the box's left and right edges land on the same wall plane.
                    let leftEdge = ray(atU: box.x, v: centreV), rightEdge = ray(atU: box.x + box.width, v: centreV)
                    if let a = wall(leftEdge, segment, slack: 3, room: room),
                       let b = wall(rightEdge, segment, slack: 3, room: room) {
                        let span = simd_length(SIMD2(a.point.x - b.point.x, a.point.z - b.point.z))
                        if span >= 0.25, span <= 6 { placed.length = span }
                    }
                }
                return placed
            }
            // No wall in the plan along this ray: use the floor or ceiling the ray runs into, if close enough.
            let fallbackY = centre.direction.y < 0 ? room.floorY : room.ceilingY
            guard let hit = horizontalPlane(centre, y: fallbackY), hit.distance <= maxDistance else { return nil }
            return Placed(surface: .wall, position: hit.point, axis: nil, length: nil, distance: hit.distance)
        }
    }

    // MARK: Merging

    /// Collapses repeat sightings into fixtures. Highest-confidence sighting leads each group (its photo is kept);
    /// lone sightings under `minSingleConfidence` are dropped.
    static func merge(_ sightings: [Sighting]) -> [Fixture] {
        struct Group {
            var lead: Sighting
            var members: [Sighting]
            var position: SIMD3<Float>
            var length: Float?
            var span: ClosedRange<Float>?       // heaters: interval along the wall axis
        }
        var groups: [Group] = []

        func along(_ s: Sighting, axis: SIMD2<Float>) -> ClosedRange<Float> {
            let c = s.placed.position.x * axis.x + s.placed.position.z * axis.y
            let half = (s.placed.length ?? 0.4) / 2
            return (c - half)...(c + half)
        }

        for s in sightings.sorted(by: { $0.confidence > $1.confidence }) {
            var joined = false
            for i in groups.indices where groups[i].lead.kind == s.kind {
                if s.kind == .baseboardHeater, let a = groups[i].lead.placed.axis, let b = s.placed.axis {
                    // Same wall: parallel, close across the wall, and overlapping (or nearly touching) along it.
                    let parallel = abs(simd_dot(a, b)) > 0.97
                    let across = SIMD2(a.y, -a.x)
                    let delta = SIMD2(s.placed.position.x - groups[i].position.x, s.placed.position.z - groups[i].position.z)
                    guard parallel, abs(simd_dot(delta, across)) < 0.3, let span = groups[i].span else { continue }
                    let mine = along(s, axis: a)
                    guard mine.lowerBound <= span.upperBound + 0.3, mine.upperBound >= span.lowerBound - 0.3 else { continue }
                    let merged = min(span.lowerBound, mine.lowerBound)...max(span.upperBound, mine.upperBound)
                    groups[i].span = merged
                    groups[i].length = merged.upperBound - merged.lowerBound
                    let mid = (merged.lowerBound + merged.upperBound) / 2
                    let lead = groups[i].lead.placed.position
                    let base = SIMD2(lead.x, lead.z)
                    let shifted = base + a * (mid - (base.x * a.x + base.y * a.y))
                    groups[i].position = SIMD3(shifted.x, lead.y, shifted.y)
                    groups[i].members.append(s)
                    joined = true
                    break
                }
                guard s.kind != .baseboardHeater else { continue }
                if simd_distance(groups[i].position, s.placed.position) < mergeRadius {
                    groups[i].members.append(s)
                    joined = true
                    break
                }
            }
            if !joined {
                var g = Group(lead: s, members: [s], position: s.placed.position, length: s.placed.length, span: nil)
                if s.kind == .baseboardHeater, let axis = s.placed.axis { g.span = along(s, axis: axis) }
                groups.append(g)
            }
        }

        return groups.compactMap { g in
            guard g.members.count > 1 || g.lead.confidence >= minSingleConfidence else { return nil }
            return Fixture(kind: g.lead.kind, surface: g.lead.placed.surface, position: g.position,
                           planPosition: SIMD2(g.position.x, g.position.z),
                           length: g.length, axis: g.lead.placed.axis,
                           photoFrame: g.lead.photoFrame, photoBox: g.lead.photoBox,
                           source: .detected, confidence: g.lead.confidence)
        }
    }

    // MARK: Manual tagging

    /// Where a hand-tagged fixture goes: about `reach` metres out from the photo spot along its facing direction,
    /// pulled onto the nearest wall within 2 m of that point. With no walls, or no facing, it sits at the spot.
    static func manualPlan(spot: SIMD2<Float>, facing: SIMD2<Float>?, walls: [FloorPlan.Segment],
                           reach: Float = 1.5) -> (point: SIMD2<Float>, axis: SIMD2<Float>?) {
        guard !walls.isEmpty else { return (spot, nil) }
        let target = facing.map { spot + $0 * reach } ?? spot
        var best: (point: SIMD2<Float>, axis: SIMD2<Float>, distance: Float)?
        for w in walls {
            let e = w.end - w.start
            let l2 = simd_length_squared(e)
            guard l2 > 1e-6 else { continue }
            let s = min(max(simd_dot(target - w.start, e) / l2, 0), 1)
            let p = w.start + e * s
            let d = simd_distance(p, target)
            if best == nil || d < best!.distance { best = (p, e / l2.squareRoot(), d) }
        }
        guard let best, best.distance <= 2 else { return (target, nil) }
        return (best.point, best.axis)
    }
}

#if DEBUG
extension FixturePlacement {
    /// Quick checks of the ray math. Run with the launch argument `-TildaSelfCheck`; returns failure messages.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 0.01) -> Bool { simd_distance(a, b) < eps }

        // Camera at (0, 1.4, 0), no rotation (looks down -Z, +Y up): sensor 1920x1440, f = 1500, centre (960, 720).
        let cam = Camera(transform: matrix_identity_float4x4, fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(0, 1.4, 0, 1)
        let camera = Camera(transform: t, fx: cam.fx, fy: cam.fy, cx: cam.cx, cy: cam.cy, width: cam.width, height: cam.height)
        let room = Room(floorY: 0, ceilingY: 2.5, walls: [.init(start: [-2, -3], end: [2, -3])])

        // Pixel mapping: the sensor's top-left corner is the upright photo's top-right when turned clockwise.
        expect(sensorPixel(u: 1, v: 0, orientation: .right, width: 1920, height: 1440) == SIMD2(0, 0), "right maps top-right to sensor origin")
        expect(sensorPixel(u: 0, v: 0, orientation: .left, width: 1920, height: 1440) == SIMD2(1920, 0), "left maps top-left to sensor top-right")

        // Photo centre looks straight ahead and lands on the wall at z = -3.
        let straight = place(kind: .hvacVent, surface: .wall, box: .init(x: 0.49, y: 0.49, width: 0.02, height: 0.02),
                             orientation: .up, camera: camera, room: room)
        expect(straight.map { near($0.position, SIMD3(0, 1.4, -3)) } ?? false, "centre ray hits the wall at (0, 1.4, -3)")

        // 15 degrees below the axis: lands on the floor 1.4 / tan(15 deg) ~ 5.22 m ahead of the camera, but the wall at
        // 3 m comes first, so a floor vent there is rejected.
        let pixelY = 720 + 1500 * tan(15 * Float.pi / 180)
        let down = place(kind: .hvacVent, surface: .floor, box: .init(x: 0.49, y: (pixelY / 1440) - 0.01, width: 0.02, height: 0.02),
                         orientation: .up, camera: camera, room: room)
        expect(down == nil, "floor hit behind the wall is discarded")

        // 30 degrees below the axis in a deeper room: floor hit at 1.4 / tan(30 deg) ~ 2.425 m ahead.
        let deep = Room(floorY: 0, ceilingY: 2.5, walls: [.init(start: [-5, -6], end: [5, -6])])
        let pY = 720 + 1500 * tan(30 * Float.pi / 180)
        let floorHit = place(kind: .hvacVent, surface: .floor, box: .init(x: 0.49, y: (pY / 1440) - 0.01, width: 0.02, height: 0.02),
                             orientation: .up, camera: camera, room: deep)
        expect(floorHit.map { near($0.position, SIMD3(0, 0, -2.425), 0.02) } ?? false, "30 degrees down hits the floor at z = -2.425")

        // Heater: a 1.2 m unit centred on the wall, seen from 3 m: box width ~ 1.2 / 3 * 1500 / 1920 of the photo.
        let w = Float(1.2 / 3 * 1500 / 1920)
        let heater = place(kind: .baseboardHeater, surface: .wall, box: .init(x: 0.5 - w / 2, y: 0.49, width: w, height: 0.02),
                           orientation: .up, camera: camera, room: room)
        expect(heater?.length.map { abs($0 - 1.2) < 0.05 } ?? false, "heater length is about 1.2 m")

        // Merging: two sightings 0.3 m apart become one; a lone faint sighting is dropped; a lone strong one stays.
        func sighting(_ p: SIMD3<Float>, _ c: Float, kind: Fixture.Kind = .hvacVent) -> Sighting {
            Sighting(kind: kind, placed: .init(surface: .ceiling, position: p, axis: nil, length: nil, distance: 2),
                     confidence: c, photoFrame: "images/a.jpg", photoBox: .init(x: 0, y: 0, width: 0.1, height: 0.1))
        }
        let merged = merge([sighting([1, 2.4, 1], 0.5), sighting([1.3, 2.4, 1], 0.8), sighting([4, 2.4, 4], 0.5),
                            sighting([6, 2.4, 6], 0.9, kind: .bathroomFan)])
        expect(merged.count == 2, "merge keeps two fixtures (got \(merged.count))")
        expect(merged.first { $0.kind == .hvacVent }?.confidence == 0.8, "merged fixture keeps the best photo")
        return failures
    }
}
#endif
