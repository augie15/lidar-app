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
    /// Heaters are mistaken for trim so often that a lone (verified) sighting must be this sure.
    static let minSingleHeaterConfidence: Float = 0.8
    static let defaultCeilingHeight: Float = 2.4

    // Heater geometry. A heater is low on a wall, so the floor under its bottom edge is the most reliable clue.
    /// How far the floor point under a heater may be from the nearest wall segment.
    static let heaterWallSnap: Float = 0.45
    /// The top of the box may reach this high above the floor where it meets the wall; the bottom, this high.
    static let heaterMaxTop: Float = 0.6
    static let heaterMaxBottom: Float = 0.25
    static let heaterLengthRange: ClosedRange<Float> = 0.3...6
    /// A box this close to the left or right photo edge is cut off by the photo, so its length is only a minimum.
    static let edgeTouch: Float = 0.02

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
        /// Heaters: the box touched the photo edge, so `length` is only a minimum (the unit runs on out of frame).
        var lengthIsLowerBound: Bool = false
        /// Heaters: index of the wall segment in `Room.walls` the unit sits on, so repeat sightings only join on the same one.
        var wallIndex: Int?
    }

    /// One detection in one photo, already placed in the room.
    struct Sighting: Sendable {
        var kind: Fixture.Kind
        var placed: Placed
        var confidence: Float
        var photoFrame: String
        var photoBox: NormalizedBox
        /// Heaters: the close-up second look agreed it is a real baseboard heater.
        var verified: Bool = false
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
        // Heaters have their own floor-anchored geometry (see `placeHeater`).
        if kind == .baseboardHeater {
            return placeHeater(box: box, orientation: orientation, camera: camera, room: room)
        }
        let surface = claimed
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
                return Placed(surface: .wall, position: wallHit.point, axis: wallHit.wallAxis,
                              length: nil, distance: wallHit.distance)
            }
            // No wall in the plan along this ray: use the floor or ceiling the ray runs into, if close enough.
            let fallbackY = centre.direction.y < 0 ? room.floorY : room.ceilingY
            guard let hit = horizontalPlane(centre, y: fallbackY), hit.distance <= maxDistance else { return nil }
            return Placed(surface: .wall, position: hit.point, axis: nil, length: nil, distance: hit.distance)
        }
    }

    // MARK: Placing a heater

    /// Nearest wall segment to a plan point: its index, the closest point on it, how far along it that is, and the distance.
    static func nearestSegment(to p: SIMD2<Float>, walls: [FloorPlan.Segment])
        -> (index: Int, point: SIMD2<Float>, along: Float, axis: SIMD2<Float>, distance: Float)? {
        var best: (index: Int, point: SIMD2<Float>, along: Float, axis: SIMD2<Float>, distance: Float)?
        for (i, w) in walls.enumerated() {
            let e = w.end - w.start
            let l = simd_length(e)
            guard l > 1e-3 else { continue }
            let along = min(max(simd_dot(p - w.start, e) / l, 0), l)
            let q = w.start + e / l * along
            let d = simd_distance(q, p)
            if best == nil || d < best!.distance { best = (i, q, along, e / l, d) }
        }
        return best
    }

    /// Where a baseboard heater sits, worked out from the floor under it rather than from the box centre. A heater is a
    /// thin strip at the bottom of the photo, and the centre ray of a thin low box can slip through a doorway or hit
    /// the wrong wall; the floor point under the bottom edge cannot. `box` is in the upright photo (fractions).
    /// Returns nil when no wall is near that floor point, or the box is too high on the wall to be a heater.
    static func placeHeater(box: NormalizedBox, orientation: Orientation, camera: Camera, room: Room) -> Placed? {
        func ray(atU u: Float, v: Float) -> Ray {
            self.ray(camera: camera, sensorPixel: sensorPixel(u: u, v: v, orientation: orientation,
                                                              width: camera.width, height: camera.height))
        }
        let midU = box.x + box.width / 2, bottomV = box.y + box.height
        guard let anchor = horizontalPlane(ray(atU: midU, v: bottomV), y: room.floorY), anchor.distance <= maxDistance,
              let snap = nearestSegment(to: SIMD2(anchor.point.x, anchor.point.z), walls: room.walls),
              snap.distance <= heaterWallSnap else { return nil }
        // The floor-anchored wall wins over wherever the centre ray lands (a far wall seen through a doorway, say).
        let segment = room.walls[snap.index]
        let segmentLength = simd_length(segment.end - segment.start)

        // A heater is low on its wall: where the top and bottom edges meet the wall plane, check the height.
        func heightOnWall(v: Float) -> Float? {
            wall(ray(atU: midU, v: v), segment, slack: 1000, room: room).map { $0.point.y - room.floorY }
        }
        guard let top = heightOnWall(v: box.y), top <= heaterMaxTop,
              let bottom = heightOnWall(v: bottomV), bottom <= heaterMaxBottom else { return nil }

        // Length: the bottom-left and bottom-right floor points, projected along the wall and kept on the segment.
        func alongWall(u: Float) -> Float? {
            guard let h = horizontalPlane(ray(atU: u, v: bottomV), y: room.floorY), h.distance <= maxDistance else { return nil }
            let s = simd_dot(SIMD2(h.point.x, h.point.z) - segment.start, snap.axis)
            return min(max(s, 0), segmentLength)
        }
        var centreAlong = snap.along
        var length: Float?
        if let a = alongWall(u: box.x), let b = alongWall(u: box.x + box.width) {
            let span = abs(a - b)
            if heaterLengthRange.contains(span) {
                length = span
                centreAlong = (a + b) / 2
            }
        }
        let clipped = box.x <= edgeTouch || box.x + box.width >= 1 - edgeTouch
        let p = segment.start + snap.axis * centreAlong
        return Placed(surface: .wall, position: SIMD3(p.x, room.floorY + 0.15, p.y), axis: snap.axis, length: length,
                      distance: anchor.distance, lengthIsLowerBound: clipped, wallIndex: snap.index)
    }

    /// Whether the close-up second look keeps a heater: the model says it is one, it is not trim or a freestanding
    /// radiator, and at least one hardware clue (fins or slots, end caps, standing out from the wall) is present.
    static func heaterVerdictAccepted(isHeater: Bool, plainTrim: Bool, freestanding: Bool,
                                      fins: Bool, endCaps: Bool, standsOut: Bool) -> Bool {
        isHeater && !plainTrim && !freestanding && (fins || endCaps || standsOut)
    }

    /// True when two boxes (fractions, same photo) mostly cover the same spot: the overlap is a large share of the
    /// smaller one. Used to avoid counting a heater twice when two model calls both found it.
    static func boxesOverlap(_ a: NormalizedBox, _ b: NormalizedBox, threshold: Float = 0.3) -> Bool {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard w > 0, h > 0 else { return false }
        return w * h / max(min(a.width * a.height, b.width * b.height), 1e-6) > threshold
    }

    /// The pixel rectangle to show the model for a close-up of `box` (fractions of an image `imageWidth` by
    /// `imageHeight`): padded on every side, at least `minShortSide` pixels on the short side when the image allows,
    /// and kept inside the image by sliding rather than shrinking.
    static func cropRect(box: NormalizedBox, imageWidth W: Float, imageHeight H: Float,
                         padding: Float = 0.35, minShortSide: Float = 256) -> CGRect {
        var w = box.width * W * (1 + 2 * padding), h = box.height * H * (1 + 2 * padding)
        w = min(max(w, minShortSide), W)
        h = min(max(h, minShortSide), H)
        let cx = (box.x + box.width / 2) * W, cy = (box.y + box.height / 2) * H
        let x = min(max(cx - w / 2, 0), W - w), y = min(max(cy - h / 2, 0), H - h)
        return CGRect(x: CGFloat(x.rounded()), y: CGFloat(y.rounded()), width: CGFloat(w.rounded()), height: CGFloat(h.rounded()))
    }

    // MARK: Choosing frames

    /// Where a keyframe's camera is and which way it faces on the floor plan.
    struct Pose: Sendable {
        var position: SIMD3<Float>
        var yaw: Float
    }

    /// The camera's heading (radians) from its camera-to-world transform; the camera looks down its -Z axis.
    static func pose(of transform: simd_float4x4) -> Pose {
        let c = transform.columns
        let forward = -SIMD3(c.2.x, c.2.y, c.2.z)
        return Pose(position: SIMD3(c.3.x, c.3.y, c.3.z), yaw: atan2(forward.x, forward.z))
    }

    /// The camera is tilted down enough to see the base of a wall (forward y below `limit`).
    static func looksDown(_ transform: simd_float4x4, limit: Float = -0.25) -> Bool {
        -transform.columns.2.y < limit
    }

    /// Up to `limit` indexes into `candidates`, greedily the ones farthest (by position, then heading) from everything
    /// already picked, skipping near-duplicates of `existing` and of each other.
    static func spreadPicks(candidates: [Pose], existing: [Pose], limit: Int,
                            minDistance: Float = 0.5, minYaw: Float = 0.5) -> [Int] {
        func yawGap(_ a: Float, _ b: Float) -> Float {
            var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            return d
        }
        var taken = existing
        var picked: [Int] = []
        while picked.count < limit {
            var best: (index: Int, score: Float)?
            for (i, c) in candidates.enumerated() where !picked.contains(i) {
                var score = Float.greatestFiniteMagnitude
                var duplicate = false
                for t in taken {
                    let d = simd_distance(c.position, t.position), g = yawGap(c.yaw, t.yaw)
                    if d < minDistance && g < minYaw { duplicate = true; break }
                    score = min(score, d + 0.5 * g)
                }
                if !duplicate, best == nil || score > best!.score { best = (i, score) }
            }
            guard let best else { break }
            picked.append(best.index)
            taken.append(candidates[best.index])
        }
        return picked
    }

    // MARK: Merging

    /// Collapses repeat sightings into fixtures. Highest-confidence sighting leads each group (its photo is kept);
    /// lone sightings under `minSingleConfidence` are dropped.
    ///
    /// Heaters are stricter: only verified sightings count, they join only on the same wall segment, and a heater needs
    /// two verified sightings, or one with confidence of `minSingleHeaterConfidence`.
    static func merge(_ sightings: [Sighting]) -> [Fixture] {
        struct Group {
            var lead: Sighting
            var members: [Sighting]
            var position: SIMD3<Float>
            var length: Float?
            // Heaters: intervals along the wall axis. `exact` unions sightings whose length was measured whole;
            // `loose` unions sightings cut off by the photo edge or with no length. Loose only ever extends exact.
            var exact: ClosedRange<Float>?
            var loose: ClosedRange<Float>?
            var span: ClosedRange<Float>? { union(exact, loose) }
        }
        func union(_ a: ClosedRange<Float>?, _ b: ClosedRange<Float>?) -> ClosedRange<Float>? {
            guard let a else { return b }
            guard let b else { return a }
            return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
        }
        var groups: [Group] = []

        func along(_ s: Sighting, axis: SIMD2<Float>) -> ClosedRange<Float> {
            let c = s.placed.position.x * axis.x + s.placed.position.z * axis.y
            let half = (s.placed.length ?? 0.4) / 2
            return (c - half)...(c + half)
        }
        func isExact(_ s: Sighting) -> Bool { s.placed.length != nil && !s.placed.lengthIsLowerBound }

        for s in sightings.sorted(by: { $0.confidence > $1.confidence }) {
            if s.kind == .baseboardHeater && !s.verified { continue }
            var joined = false
            for i in groups.indices where groups[i].lead.kind == s.kind {
                if s.kind == .baseboardHeater, let a = groups[i].lead.placed.axis, let b = s.placed.axis {
                    // Same wall segment: the same plan segment, close across it, and overlapping (or nearly touching)
                    // along it. Two walls a hand's width apart (either side of a partition) never join.
                    let parallel = abs(simd_dot(a, b)) > 0.97
                    let across = SIMD2(a.y, -a.x)
                    let delta = SIMD2(s.placed.position.x - groups[i].position.x, s.placed.position.z - groups[i].position.z)
                    // RoomPlan can split one wall into collinear pieces: a heater across the break is still one heater.
                    // Heaters sit on their wall line, so different segments join only when they are in line.
                    if let wi = groups[i].lead.placed.wallIndex, let wj = s.placed.wallIndex, wi != wj,
                       abs(simd_dot(delta, across)) > 0.1 { continue }
                    guard parallel, abs(simd_dot(delta, across)) < 0.3, let span = groups[i].span else { continue }
                    let mine = along(s, axis: a)
                    guard mine.lowerBound <= span.upperBound + 0.3, mine.upperBound >= span.lowerBound - 0.3 else { continue }
                    if isExact(s) { groups[i].exact = union(groups[i].exact, mine) } else { groups[i].loose = union(groups[i].loose, mine) }
                    let merged = groups[i].span!
                    // A length is known once any member measured one.
                    if groups[i].length != nil || s.placed.length != nil { groups[i].length = merged.upperBound - merged.lowerBound }
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
                var g = Group(lead: s, members: [s], position: s.placed.position, length: s.placed.length)
                if s.kind == .baseboardHeater, let axis = s.placed.axis {
                    if isExact(s) { g.exact = along(s, axis: axis) } else { g.loose = along(s, axis: axis) }
                }
                groups.append(g)
            }
        }

        return groups.compactMap { g in
            if g.lead.kind == .baseboardHeater {
                guard g.members.count > 1 || g.lead.confidence >= minSingleHeaterConfidence else { return nil }
            } else {
                guard g.members.count > 1 || g.lead.confidence >= minSingleConfidence else { return nil }
            }
            return Fixture(kind: g.lead.kind, surface: g.lead.placed.surface, position: g.position,
                           planPosition: SIMD2(g.position.x, g.position.z),
                           length: g.length, axis: g.lead.placed.axis,
                           photoFrame: g.lead.photoFrame, photoBox: g.lead.photoBox,
                           source: .detected, confidence: g.lead.confidence)
        }
    }

    // MARK: Editing

    /// Height of a fixture's centre above the world origin for a surface: floor and ceiling units sit on the plane,
    /// wall units low on the wall (heaters right above the floor).
    static func height(kind: Fixture.Kind, surface: Fixture.Surface, room: Room) -> Float {
        switch surface {
        case .floor: room.floorY
        case .ceiling: room.ceilingY
        case .wall: room.floorY + (kind == .baseboardHeater ? 0.15 : 0.3)
        }
    }

    struct WallSnap: Sendable, Equatable {
        var point: SIMD2<Float>
        var axis: SIMD2<Float>
        var distance: Float
    }

    /// Nearest point on any wall segment. `inset` keeps the point at least that far from either end of the segment
    /// (so a heater of length `2 * inset` stays on the wall); a segment shorter than `2 * inset` snaps to its middle.
    static func snapToWall(_ p: SIMD2<Float>, walls: [FloorPlan.Segment], inset: Float = 0) -> WallSnap? {
        var best: WallSnap?
        for w in walls {
            let e = w.end - w.start
            let l = simd_length(e)
            guard l > 1e-3 else { continue }
            let along = simd_dot(p - w.start, e) / l
            let lo = min(inset, l / 2), hi = l - lo
            let c = min(max(along, lo), hi)
            let q = w.start + e / l * c
            let d = simd_distance(q, p)
            if best == nil || d < best!.distance { best = WallSnap(point: q, axis: e / l, distance: d) }
        }
        return best
    }

    /// The fixture moved to a plan point, keeping its height. A fixture on a wall is pulled onto the nearest wall
    /// segment (and takes its direction); anything else goes exactly where it is put. Flags are the caller's business.
    static func moved(_ f: Fixture, to p: SIMD2<Float>, room: Room) -> Fixture {
        var out = f
        if f.surface == .wall, let snap = snapToWall(p, walls: room.walls, inset: (f.length ?? 0) / 2) {
            out.planPosition = snap.point
            out.axis = snap.axis
        } else {
            out.planPosition = p
        }
        out.position = SIMD3(out.planPosition.x, f.position.y, out.planPosition.y)
        return out
    }

    /// The fixture with a new kind and/or surface. Height follows the surface; a move onto a wall snaps it to the
    /// nearest one. A surface the kind cannot sit on falls back to its first allowed one. Only heaters keep a length.
    static func retargeted(_ f: Fixture, kind: Fixture.Kind, surface: Fixture.Surface, room: Room) -> Fixture {
        var out = f
        out.kind = kind
        out.surface = kind.allowedSurfaces.contains(surface) ? surface : kind.allowedSurfaces[0]
        if kind != .baseboardHeater { out.length = nil }
        let y = height(kind: kind, surface: out.surface, room: room)
        out.position.y = y
        if out.surface == .wall {
            out = moved(out, to: f.planPosition, room: room)
        } else {
            out.axis = nil
        }
        return out
    }

    /// A hand-tagged fixture at a plan point, already confirmed. No photo needed.
    static func newFixture(kind: Fixture.Kind, surface: Fixture.Surface, at p: SIMD2<Float>, room: Room) -> Fixture {
        let base = Fixture(kind: kind, surface: kind.allowedSurfaces.contains(surface) ? surface : kind.allowedSurfaces[0],
                           position: SIMD3(p.x, room.floorY, p.y), planPosition: p, length: nil, axis: nil,
                           photoFrame: nil, photoBox: nil, source: .manual, confidence: nil, confirmed: true)
        return retargeted(base, kind: kind, surface: base.surface, room: room)
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

        // Merging: two sightings 0.3 m apart become one; a lone faint sighting is dropped; a lone strong one stays.
        func sighting(_ p: SIMD3<Float>, _ c: Float, kind: Fixture.Kind = .hvacVent) -> Sighting {
            Sighting(kind: kind, placed: .init(surface: .ceiling, position: p, axis: nil, length: nil, distance: 2),
                     confidence: c, photoFrame: "images/a.jpg", photoBox: .init(x: 0, y: 0, width: 0.1, height: 0.1))
        }
        let merged = merge([sighting([1, 2.4, 1], 0.5), sighting([1.3, 2.4, 1], 0.8), sighting([4, 2.4, 4], 0.5),
                            sighting([6, 2.4, 6], 0.9, kind: .bathroomFan)])
        expect(merged.count == 2, "merge keeps two fixtures (got \(merged.count))")
        expect(merged.first { $0.kind == .hvacVent }?.confidence == 0.8, "merged fixture keeps the best photo")

        // Floor-anchored heaters. Camera 1.4 m up, tilted 20 degrees down (like a phone looking at the base of a wall).
        let tilt: Float = 20 * .pi / 180
        var tiltT = matrix_identity_float4x4
        tiltT.columns.1 = SIMD4(0, cos(tilt), -sin(tilt), 0)
        tiltT.columns.2 = SIMD4(0, sin(tilt), cos(tilt), 0)
        tiltT.columns.3 = SIMD4(0, 1.4, 0, 1)
        let down20 = Camera(transform: tiltT, fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
        // A world point to the upright (.up) photo, as fractions.
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let d = p - SIMD3(tiltT.columns.3.x, tiltT.columns.3.y, tiltT.columns.3.z)
            let local = SIMD3(simd_dot(SIMD3(tiltT.columns.0.x, tiltT.columns.0.y, tiltT.columns.0.z), d),
                              simd_dot(SIMD3(tiltT.columns.1.x, tiltT.columns.1.y, tiltT.columns.1.z), d),
                              simd_dot(SIMD3(tiltT.columns.2.x, tiltT.columns.2.y, tiltT.columns.2.z), d))
            return SIMD2((960 + 1500 * local.x / -local.z) / 1920, (720 - 1500 * local.y / -local.z) / 1440)
        }
        // The box around a world-space rectangle on the wall plane: x range, y range, wall z.
        func box(x0: Float, x1: Float, y0: Float, y1: Float, z: Float) -> NormalizedBox {
            let pts = [project([x0, y0, z]), project([x1, y0, z]), project([x0, y1, z]), project([x1, y1, z])]
            let lo = pts.reduce(pts[0], simd_min), hi = pts.reduce(pts[0], simd_max)
            return NormalizedBox(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        }
        let nearWall = FloorPlan.Segment(start: [-3, -2.5], end: [3, -2.5])
        let farWall = FloorPlan.Segment(start: [-3, -6], end: [3, -6])
        let heaterRoom = Room(floorY: 0, ceilingY: 2.5, walls: [nearWall, farWall])

        // A 1.2 m heater from x = -0.3 to 0.9 on the wall 2.5 m away, 0.2 m tall, near the bottom of the photo.
        let hb = box(x0: -0.3, x1: 0.9, y0: 0, y1: 0.2, z: -2.5)
        expect(hb.y + hb.height < 0.95, "test heater is inside the photo")
        let hp = placeHeater(box: hb, orientation: .up, camera: down20, room: heaterRoom)
        expect(hp?.wallIndex == 0 && hp?.axis == SIMD2<Float>(1, 0), "heater snaps to the wall in front of it")
        expect(hp?.length.map { abs($0 - 1.2) < 0.05 } ?? false, "floor-anchored heater length is about 1.2 m (got \(hp?.length ?? -1))")
        expect(hp.map { near($0.position, SIMD3(0.3, 0.15, -2.5), 0.05) } ?? false, "heater sits at the middle of its span, 0.15 m up")
        expect(hp?.lengthIsLowerBound == false, "a whole heater is not marked as a minimum")
        let viaPlace = place(kind: .baseboardHeater, surface: .ceiling, box: hb, orientation: .up, camera: down20, room: heaterRoom)
        expect(viaPlace?.wallIndex == 0 && viaPlace?.surface == .wall, "place() routes heaters to the floor-anchored path")

        // Cut off by the photo's left edge: the length is a minimum only.
        var clippedBox = hb
        clippedBox.width = hb.x + hb.width
        clippedBox.x = 0
        let clipped = placeHeater(box: clippedBox, orientation: .up, camera: down20, room: heaterRoom)
        expect(clipped?.lengthIsLowerBound == true, "a box touching the photo edge is a length minimum")

        // Floor point 0.9 m in front of the wall: nothing to attach to.
        let floating = box(x0: 0, x1: 0.5, y0: 0, y1: 0.2, z: -1.6)
        expect(placeHeater(box: floating, orientation: .up, camera: down20, room: heaterRoom) == nil,
               "a box whose floor point is far from any wall is rejected")

        // High on the wall (a vent at window height) and a tall box that starts at the floor (a door or cabinet).
        let high = box(x0: 0, x1: 1, y0: 0.9, y1: 1.2, z: -2.5)
        expect(placeHeater(box: high, orientation: .up, camera: down20, room: heaterRoom) == nil, "a box high on the wall is rejected")
        let tall = box(x0: 0, x1: 1, y0: 0, y1: 1.0, z: -2.5)
        expect(placeHeater(box: tall, orientation: .up, camera: down20, room: heaterRoom) == nil, "a tall box from the floor is rejected")

        // Doorway: the near wall stops at x = -0.1 (a door opening to the room beyond). The box's centre ray passes through
        // the opening and misses it (a far wall or the floor beyond), but the floor point is by the near wall's end.
        let doorRoom = Room(floorY: 0, ceilingY: 2.5, walls: [.init(start: [-3, -2.5], end: [-0.1, -2.5]), farWall])
        let doorBox = box(x0: -0.3, x1: 0.7, y0: 0, y1: 0.2, z: -2.5)
        let centreRay = ray(camera: down20, sensorPixel: sensorPixel(u: doorBox.x + doorBox.width / 2, v: doorBox.y + doorBox.height / 2,
                                                                   orientation: .up, width: 1920, height: 1440))
        expect((nearestWall(centreRay, room: doorRoom)?.distance ?? .infinity) > 5, "doorway test: the centre ray misses the near wall")
        let door = placeHeater(box: doorBox, orientation: .up, camera: down20, room: doorRoom)
        expect(door?.wallIndex == 0, "doorway: the near wall wins over the far wall seen through the opening")

        // Overlap, crop and verdict helpers.
        expect(boxesOverlap(.init(x: 0.1, y: 0.8, width: 0.3, height: 0.05), .init(x: 0.15, y: 0.78, width: 0.3, height: 0.08)), "overlapping boxes overlap")
        expect(!boxesOverlap(.init(x: 0.1, y: 0.8, width: 0.1, height: 0.05), .init(x: 0.5, y: 0.8, width: 0.1, height: 0.05)), "apart boxes do not")
        let crop = cropRect(box: .init(x: 0.02, y: 0.9, width: 0.3, height: 0.04), imageWidth: 1440, imageHeight: 1920)
        expect(crop.minX >= 0 && crop.maxX <= 1440 && crop.minY >= 0 && crop.maxY <= 1920, "crop stays inside the image")
        expect(min(crop.width, crop.height) >= 256 && crop.width > 0.3 * 1440, "crop is padded and at least 256 px on its short side")
        expect(heaterVerdictAccepted(isHeater: true, plainTrim: false, freestanding: false, fins: false, endCaps: false, standsOut: true), "verdict keeps a real heater")
        expect(!heaterVerdictAccepted(isHeater: true, plainTrim: true, freestanding: false, fins: true, endCaps: true, standsOut: true), "verdict drops trim")
        expect(!heaterVerdictAccepted(isHeater: true, plainTrim: false, freestanding: false, fins: false, endCaps: false, standsOut: false), "verdict needs a hardware clue")
        expect(!heaterVerdictAccepted(isHeater: true, plainTrim: false, freestanding: true, fins: true, endCaps: true, standsOut: true), "verdict drops a freestanding radiator")

        // Frame picking: looking down, and spread without near-duplicates.
        var pitched = matrix_identity_float4x4
        pitched.columns.2 = SIMD4(0, 0.5, 0.866, 0)       // forward y = -0.5
        expect(looksDown(pitched) && !looksDown(matrix_identity_float4x4), "looksDown tells a downward camera from a level one")
        let poses = [Pose(position: [0, 1.4, 0], yaw: 0), Pose(position: [0.1, 1.4, 0], yaw: 0.1),
                     Pose(position: [3, 1.4, 0], yaw: 0), Pose(position: [0, 1.4, 0], yaw: 3)]
        let picks = spreadPicks(candidates: poses, existing: [Pose(position: [0, 1.4, 0], yaw: 0)], limit: 8)
        expect(Set(picks) == [2, 3], "spread picks skip near-duplicates of existing frames (got \(picks))")

        // Heater merging. Helper: a verified heater sighting on segment `wall`, centred `x` along x, `length` long.
        func heaterSighting(_ wall: Int?, z: Float = -2.5, x: Float, length: Float?, lowerBound: Bool = false,
                            confidence: Float, verified: Bool = true) -> Sighting {
            Sighting(kind: .baseboardHeater,
                     placed: .init(surface: .wall, position: [x, 0.15, z], axis: [1, 0], length: length, distance: 2.5,
                                   lengthIsLowerBound: lowerBound, wallIndex: wall),
                     confidence: confidence, photoFrame: "images/a.jpg", photoBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                     verified: verified)
        }
        // Walls on either side of a thin partition, 0.25 m apart, are different segments: never one heater.
        let sides = merge([heaterSighting(0, z: -2.5, x: 0, length: 1, confidence: 0.85),
                           heaterSighting(1, z: -2.25, x: 0, length: 1, confidence: 0.85)])
        expect(sides.count == 2, "heaters on different wall segments 0.25 m apart stay separate (got \(sides.count))")
        let splitWall = merge([heaterSighting(0, x: -0.4, length: 1, confidence: 0.85),
                               heaterSighting(1, x: 0.4, length: 1, confidence: 0.6)])
        expect(splitWall.count == 1 && (splitWall.first?.length).map { abs($0 - 1.8) < 0.01 } ?? false,
               "a heater across a break between collinear wall pieces is one heater")
        let joinedH = merge([heaterSighting(0, x: 0, length: 1, confidence: 0.5), heaterSighting(0, x: 0.6, length: 1, confidence: 0.6)])
        expect(joinedH.count == 1 && (joinedH.first?.length).map { abs($0 - 1.6) < 0.01 } ?? false, "two verified overlapping sightings join into one 1.6 m heater")
        expect(merge([heaterSighting(0, x: 0, length: 1, confidence: 0.75)]).isEmpty, "a lone verified heater under 0.8 is dropped")
        expect(merge([heaterSighting(0, x: 0, length: 1, confidence: 0.85)]).count == 1, "a lone verified heater at 0.85 stays")
        expect(merge([heaterSighting(0, x: 0, length: 1, confidence: 0.95, verified: false)]).isEmpty, "an unverified heater is dropped")
        let withClip = merge([heaterSighting(0, x: 0, length: 1, confidence: 0.9),
                              heaterSighting(0, x: 0.2, length: 0.6, lowerBound: true, confidence: 0.6)])
        expect(withClip.count == 1 && (withClip.first?.length).map { abs($0 - 1) < 0.01 } ?? false, "a clipped sighting inside a whole one changes nothing")
        let extended = merge([heaterSighting(0, x: 0, length: 1, confidence: 0.9),
                              heaterSighting(0, x: 0.8, length: 1, lowerBound: true, confidence: 0.6)])
        expect(extended.count == 1 && (extended.first?.length).map { abs($0 - 1.8) < 0.01 } ?? false, "a clipped sighting can extend a whole one")
        let clipLead = merge([heaterSighting(0, x: 0.2, length: 0.6, lowerBound: true, confidence: 0.9),
                              heaterSighting(0, x: 0, length: 1, confidence: 0.6)])
        expect(clipLead.first?.length.map { abs($0 - 1) < 0.01 } ?? false, "a whole sighting's span is kept even when a clipped one leads")

        // Snap and move: walls along the x axis at z = 0 and the y axis at x = 4 (a corner).
        let editRoom = Room(floorY: 0, ceilingY: 2.5, walls: [.init(start: [0, 0], end: [4, 0]), .init(start: [4, 0], end: [4, 3])])
        let snap = snapToWall([1.5, 0.4], walls: editRoom.walls)
        expect(snap.map { simd_distance($0.point, [1.5, 0]) < 1e-4 && $0.axis == [1, 0] && abs($0.distance - 0.4) < 1e-4 } ?? false,
               "snap lands on the nearest wall")
        expect(snapToWall([3.8, 1.0], walls: editRoom.walls)?.point == SIMD2<Float>(4, 1), "snap prefers the closer wall")
        expect(snapToWall([0.1, 0.2], walls: editRoom.walls, inset: 0.6)?.point == SIMD2<Float>(0.6, 0), "snap keeps a heater's ends on the wall")
        expect(snapToWall([1, 1], walls: []) == nil, "no walls, no snap")

        let editHeater = Fixture(kind: .baseboardHeater, surface: .wall, position: [1, 0.15, 0], planPosition: [1, 0], length: 1.2,
                             axis: [1, 0], photoFrame: nil, photoBox: nil, source: .detected, confidence: 0.9)
        let m = moved(editHeater, to: [3.9, 2.0], room: editRoom)
        expect(m.planPosition == SIMD2<Float>(4, 2) && m.axis == [0, 1], "heater moved onto the side wall turns with it")
        expect(m.position == SIMD3<Float>(4, 0.15, 2), "move keeps height and writes the 3D position")
        let end = moved(editHeater, to: [3.7, 0.1], room: editRoom)
        expect(end.planPosition.x <= 3.4 + 1e-4 && end.planPosition.y == 0, "heater centre stays clear of the wall end")

        let vent = Fixture(kind: .hvacVent, surface: .ceiling, position: [2, 2.5, 1], planPosition: [2, 1], length: nil,
                           axis: nil, photoFrame: nil, photoBox: nil, source: .detected, confidence: 0.8)
        let mv = moved(vent, to: [1, 2], room: editRoom)
        expect(mv.position == SIMD3<Float>(1, 2.5, 2) && mv.planPosition == SIMD2<Float>(1, 2), "ceiling vent moves freely at ceiling height")
        let onWall = retargeted(vent, kind: .hvacVent, surface: .wall, room: editRoom)
        expect(onWall.planPosition == SIMD2<Float>(2, 0) && abs(onWall.position.y - 0.3) < 1e-4, "changing to wall snaps and drops to wall height")
        let asHeater = retargeted(vent, kind: .baseboardHeater, surface: .ceiling, room: editRoom)
        expect(asHeater.surface == .wall && abs(asHeater.position.y - 0.15) < 1e-4, "a heater always ends up on a wall")
        expect(retargeted(editHeater, kind: .bathroomFan, surface: .ceiling, room: editRoom).length == nil, "length is dropped when not a heater")
        let added = newFixture(kind: .bathroomFan, surface: .ceiling, at: [1, 1], room: editRoom)
        expect(added.confirmed && added.source == .manual && added.position == SIMD3<Float>(1, 2.5, 1), "new fan sits at ceiling height, confirmed")
        let addedHeater = newFixture(kind: .baseboardHeater, surface: .wall, at: [2, 0.7], room: editRoom)
        expect(addedHeater.planPosition == SIMD2<Float>(2, 0) && addedHeater.axis == [1, 0], "new heater snaps to the wall")

        // Re-detection: dismissed finds stay gone, unchecked ones keep their id, touched ones are never duplicated.
        func det(_ kind: Fixture.Kind, _ p: SIMD2<Float>) -> Fixture {
            Fixture(kind: kind, surface: .ceiling, position: [p.x, 2.5, p.y], planPosition: p, length: nil, axis: nil,
                    photoFrame: nil, photoBox: nil, source: .detected, confidence: 0.8)
        }
        var mergeLib = FixtureLibrary()
        let oldUnchecked = det(.hvacVent, [1, 1])
        var confirmedFan = det(.bathroomFan, [3, 1]); confirmedFan.confirmed = true
        mergeLib.fixtures = [oldUnchecked, confirmedFan, det(.hvacVent, [5, 5])]
        mergeLib.dismissed = [.init(kind: .hvacVent, planPosition: [2, 2])]
        let merged2 = mergeLib.merging(detections: [det(.hvacVent, [1.2, 1]), det(.bathroomFan, [3.1, 1]),
                                                    det(.hvacVent, [2.1, 2]), det(.hvacVent, [0, 3])], radius: mergeRadius)
        expect(merged2.count == 3, "re-detect keeps the fan, the matched vent and one new vent (got \(merged2.count))")
        expect(merged2.contains { $0.id == oldUnchecked.id && $0.planPosition == SIMD2<Float>(1.2, 1) },
               "a fresh sighting of an unchecked find keeps its id")
        expect(!merged2.contains { simd_distance($0.planPosition, [2.1, 2]) < 0.01 }, "a dismissed find stays deleted")
        expect(!merged2.contains { simd_distance($0.planPosition, [5, 5]) < 0.01 }, "an unchecked find not seen again is dropped")

        // Old fixtures.json (no confirmed/edited keys) still decodes: detected is unchecked, manual is confirmed.
        let old = """
        {"fixtures":[{"id":"6F1E4B9A-0000-4000-8000-000000000001","kind":"hvacVent","surface":"floor","position":[1,0,2],
        "planPosition":[1,2],"source":"detected","confidence":0.8},
        {"id":"6F1E4B9A-0000-4000-8000-000000000002","kind":"bathroomFan","surface":"ceiling","position":[1,2.4,2],
        "planPosition":[1,2],"source":"manual"}]}
        """
        if let lib = try? JSONDecoder().decode(FixtureLibrary.self, from: Data(old.utf8)) {
            expect(lib.fixtures.count == 2 && lib.fixtures[0].needsCheck && lib.fixtures[1].confirmed && !lib.fixtures[1].needsCheck,
                   "old library decodes with defaults")
            let round = try? JSONDecoder().decode(FixtureLibrary.self, from: JSONEncoder().encode(lib))
            expect(round == lib, "library round-trips with the new fields")
        } else {
            failures.append("old library failed to decode")
        }
        return failures
    }
}
#endif
