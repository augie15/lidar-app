import Foundation
import simd

/// Chooses where to put virtual cameras inside a room's splat: square-on to each wall at knee height (for heaters) and
/// looking up at the ceiling (for vents and fans). Pure geometry, no Metal and no files, so it can be checked on its
/// own (see `selfCheck`).
///
/// Cameras use the ARKit convention (looks down -Z, +Y up, camera-to-world) and one fixed pinhole, so a rendered view
/// is a `FixturePlacement.Camera` whose "sensor" image is the rendered, already upright picture.
enum SplatViewPlanner {
    struct View: Sendable {
        enum Kind: Sendable, Equatable { case wall, ceiling }
        var kind: Kind
        var camera: FixturePlacement.Camera
    }

    // Rendered picture and lens.
    static let imageWidth = 1024
    static let imageHeight = 768
    static let horizontalFOV: Float = 75 * .pi / 180

    // Wall views.
    static let wallCameraHeight: Float = 0.9
    static let wallPitchDown: Float = 20 * .pi / 180
    /// Stand-off from the wall, tried in this order. The last is only for small rooms.
    static let wallDistances: [Float] = [2.0, 1.8, 1.6, 2.2, 1.3]
    static let wallSpacing: Float = 2.0
    static let minWallLength: Float = 0.6

    // Ceiling views. Low enough that a view covers about a 2 m cell of ceiling.
    static let ceilingCameraHeight: Float = 1.3
    static let ceilingPitchUp: Float = 70 * .pi / 180
    static let ceilingSpacing: Float = 2.0

    /// A camera must be this near (on the floor plan) to a keyframe: the splat is only good where the user walked.
    static let maxKeyframeDistance: Float = 1.5
    /// And this far from any wall, so it is never inside or behind one.
    static let minWallClearance: Float = 0.5

    static let maxViews = 30
    static let ceilingShare = 10

    // MARK: Planning

    static func plan(walls: [FloorPlan.Segment], floorY: Float, ceilingHeight: Float,
                     keyframes: [SIMD3<Float>]) -> [View] {
        let spots = keyframes.map { SIMD2($0.x, $0.z) }
        guard !walls.isEmpty, !spots.isEmpty else { return [] }

        var wallViews: [View] = []
        for (index, wall) in walls.enumerated() {
            wallViews += makeWallViews(for: wall, index: index, walls: walls, floorY: floorY, spots: spots)
        }
        var ceilingViews = makeCeilingViews(walls: walls, floorY: floorY, ceilingHeight: ceilingHeight, spots: spots)

        // Thin evenly to the cap, keeping a share for the ceiling.
        let ceilingKept = min(ceilingViews.count, ceilingShare)
        let wallKept = min(wallViews.count, maxViews - ceilingKept)
        let ceilingRoom = min(ceilingViews.count, maxViews - wallKept)
        wallViews = SplatMath.evenIndices(count: wallViews.count, limit: wallKept).map { wallViews[$0] }
        ceilingViews = SplatMath.evenIndices(count: ceilingViews.count, limit: ceilingRoom).map { ceilingViews[$0] }
        return wallViews + ceilingViews
    }

    private static func makeWallViews(for wall: FloorPlan.Segment, index: Int, walls: [FloorPlan.Segment], floorY: Float,
                                  spots: [SIMD2<Float>]) -> [View] {
        let e = wall.end - wall.start
        let length = simd_length(e)
        guard length >= minWallLength else { return [] }
        let dir = e / length
        let normal = SIMD2(-dir.y, dir.x)
        let stations = max(1, Int((length / wallSpacing).rounded()))
        var views: [View] = []
        for i in 0..<stations {
            let target = wall.start + dir * (length * (Float(i) + 0.5) / Float(stations))
            var chosen: SIMD2<Float>?
            search: for d in wallDistances {
                // The side nearer the keyframes first.
                let sides: [Float] = [1, -1].sorted {
                    distanceToNearest(target + normal * $0 * d, in: spots) < distanceToNearest(target + normal * $1 * d, in: spots)
                }
                for side in sides {
                    let p = target + normal * side * d
                    if usable(p, walls: walls, spots: spots), clearView(from: p, to: target, walls: walls, skipping: index) {
                        chosen = p
                        break search
                    }
                }
            }
            guard let p = chosen else { continue }
            let toWall = simd_normalize(target - p)
            let forward = SIMD3(cos(wallPitchDown) * toWall.x, -sin(wallPitchDown), cos(wallPitchDown) * toWall.y)
            views.append(View(kind: .wall, camera: camera(position: SIMD3(p.x, floorY + wallCameraHeight, p.y), forward: forward)))
        }
        return views
    }

    private static func makeCeilingViews(walls: [FloorPlan.Segment], floorY: Float, ceilingHeight: Float,
                                     spots: [SIMD2<Float>]) -> [View] {
        let points = walls.flatMap { [$0.start, $0.end] }
        let lo = points.reduce(points[0], simd_min), hi = points.reduce(points[0], simd_max)
        // Face along the longest wall, so the picture lines up with the room.
        let longest = walls.max { simd_length($0.end - $0.start) < simd_length($1.end - $1.start) }!
        let axis = simd_normalize(longest.end - longest.start)
        let forward = SIMD3(cos(ceilingPitchUp) * axis.x, sin(ceilingPitchUp), cos(ceilingPitchUp) * axis.y)
        let height = floorY + min(ceilingCameraHeight, ceilingHeight * 0.55)

        func cells(_ extent: Float) -> Int { max(1, Int((extent / ceilingSpacing).rounded())) }
        let nx = cells(hi.x - lo.x), nz = cells(hi.y - lo.y)
        var views: [View] = []
        for ix in 0..<nx {
            for iz in 0..<nz {
                let p = SIMD2(lo.x + (hi.x - lo.x) * (Float(ix) + 0.5) / Float(nx),
                              lo.y + (hi.y - lo.y) * (Float(iz) + 0.5) / Float(nz))
                guard usable(p, walls: walls, spots: spots) else { continue }
                views.append(View(kind: .ceiling, camera: camera(position: SIMD3(p.x, height, p.y), forward: forward)))
            }
        }
        // A small or odd-shaped room can miss every grid point; use the keyframe nearest the middle instead.
        if views.isEmpty {
            let mid = (lo + hi) / 2
            if let p = spots.filter({ usable($0, walls: walls, spots: spots) }).min(by: { simd_distance($0, mid) < simd_distance($1, mid) }) {
                views.append(View(kind: .ceiling, camera: camera(position: SIMD3(p.x, height, p.y), forward: forward)))
            }
        }
        return views
    }

    // MARK: Camera

    /// A camera at `position` looking along `forward`, with no roll.
    static func camera(position: SIMD3<Float>, forward: SIMD3<Float>) -> FixturePlacement.Camera {
        let f = simd_normalize(forward)
        let right = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        let up = simd_cross(right, f)
        let transform = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-f, 0), SIMD4(position, 1)))
        let focal = Float(imageWidth) / 2 / tan(horizontalFOV / 2)
        return FixturePlacement.Camera(transform: transform, fx: focal, fy: focal, cx: Float(imageWidth) / 2,
                                       cy: Float(imageHeight) / 2, width: Float(imageWidth), height: Float(imageHeight))
    }

    // MARK: Plan-space tests

    /// Inside the room, clear of the walls, and near where the user walked.
    private static func usable(_ p: SIMD2<Float>, walls: [FloorPlan.Segment], spots: [SIMD2<Float>]) -> Bool {
        guard distanceToNearest(p, in: spots) <= maxKeyframeDistance, isInside(p, walls: walls) else { return false }
        return (FixturePlacement.nearestSegment(to: p, walls: walls)?.distance ?? .infinity) >= minWallClearance
    }

    private static func distanceToNearest(_ p: SIMD2<Float>, in spots: [SIMD2<Float>]) -> Float {
        spots.map { simd_distance($0, p) }.min() ?? .infinity
    }

    /// Even-odd test along three directions; two of three must agree, so a gap at a doorway can't flip the answer.
    static func isInside(_ p: SIMD2<Float>, walls: [FloorPlan.Segment]) -> Bool {
        let directions: [SIMD2<Float>] = [SIMD2(1, 0.0137), SIMD2(0.0211, 1), SIMD2(0.7071, 0.7071)]
        let odd = directions.filter { d in
            walls.reduce(0) { count, w in count + (crosses(origin: p, direction: d, w) ? 1 : 0) } % 2 == 1
        }
        return odd.count >= 2
    }

    private static func crosses(origin o: SIMD2<Float>, direction d: SIMD2<Float>, _ w: FloorPlan.Segment) -> Bool {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let e = w.end - w.start
        let denom = cross(d, e)
        guard abs(denom) > 1e-6 else { return false }
        let diff = w.start - o
        let t = cross(diff, e) / denom
        let s = cross(diff, d) / denom
        return t > 0 && s >= 0 && s < 1
    }

    /// No other wall between the camera and the point it aims at.
    private static func clearView(from a: SIMD2<Float>, to b: SIMD2<Float>, walls: [FloorPlan.Segment], skipping skip: Int) -> Bool {
        let d = b - a
        let length = simd_length(d)
        guard length > 0.1 else { return true }
        let unit = d / length
        for (i, w) in walls.enumerated() where i != skip {
            func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
            let e = w.end - w.start
            let denom = cross(unit, e)
            guard abs(denom) > 1e-6 else { continue }
            let diff = w.start - a
            let t = cross(diff, e) / denom
            let s = cross(diff, unit) / denom
            if t > 0.02, t < length - 0.05, s >= 0, s <= 1 { return false }
        }
        return true
    }
}

#if DEBUG
extension SplatViewPlanner {
    /// A closed rectangle of walls with its corner at `origin`.
    static func rectangle(origin: SIMD2<Float> = .zero, width w: Float, depth d: Float) -> [FloorPlan.Segment] {
        let a = origin, b = origin + SIMD2(w, 0), c = origin + SIMD2(w, d), e = origin + SIMD2(0, d)
        return [.init(start: a, end: b), .init(start: b, end: c), .init(start: c, end: e), .init(start: e, end: a)]
    }

    /// Keyframe positions on a grid inside a rectangle, 1.4 m up, like someone who walked all over the room.
    static func walkedGrid(width w: Float, depth d: Float, step: Float = 1, inset: Float = 0.8) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        var x = inset
        while x <= w - inset + 0.001 {
            var z = inset
            while z <= d - inset + 0.001 { out.append(SIMD3(x, 1.4, z)); z += step }
            x += step
        }
        return out
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // A 5 x 4 m room, walked all over.
        let walls = rectangle(width: 5, depth: 4)
        let walked = walkedGrid(width: 5, depth: 4)
        let views = plan(walls: walls, floorY: 0, ceilingHeight: 2.4, keyframes: walked)
        let wallViews = views.filter { $0.kind == .wall }, ceilingViews = views.filter { $0.kind == .ceiling }
        expect(wallViews.count == 10 && ceilingViews.count == 6, "5 x 4 m room plans 10 wall and 6 ceiling views (got \(wallViews.count), \(ceilingViews.count))")

        func position(_ c: FixturePlacement.Camera) -> SIMD3<Float> { SIMD3(c.transform.columns.3.x, c.transform.columns.3.y, c.transform.columns.3.z) }
        func forward(_ c: FixturePlacement.Camera) -> SIMD3<Float> { -SIMD3(c.transform.columns.2.x, c.transform.columns.2.y, c.transform.columns.2.z) }
        let spots = walked.map { SIMD2($0.x, $0.z) }
        expect(views.allSatisfy { isInside(SIMD2(position($0.camera).x, position($0.camera).z), walls: walls) }, "every camera is inside the room")
        expect(views.allSatisfy { distanceToNearest(SIMD2(position($0.camera).x, position($0.camera).z), in: spots) <= maxKeyframeDistance }, "every camera is near a keyframe")
        expect(wallViews.allSatisfy { abs(position($0.camera).y - wallCameraHeight) < 1e-4 }, "wall cameras are 0.9 m up")

        // Each wall camera faces a wall square-on: its horizontal heading is the wall's normal, and it pitches 20 degrees down.
        var facing = true
        for v in wallViews {
            let f = forward(v.camera)
            let horizontal = simd_normalize(SIMD2(f.x, f.z))
            let p = SIMD2(position(v.camera).x, position(v.camera).z)
            // Cast along the heading: the first wall hit must be square to the heading.
            var best: (t: Float, w: FloorPlan.Segment)?
            for w in walls {
                let e = w.end - w.start
                let denom = horizontal.x * e.y - horizontal.y * e.x
                guard abs(denom) > 1e-6 else { continue }
                let diff = w.start - p
                let t = (diff.x * e.y - diff.y * e.x) / denom
                let s = (diff.x * horizontal.y - diff.y * horizontal.x) / denom
                if t > 0, s >= 0, s <= 1, best == nil || t < best!.t { best = (t, w) }
            }
            guard let hit = best else { facing = false; continue }
            let e = simd_normalize(hit.w.end - hit.w.start)
            if abs(simd_dot(horizontal, e)) > 0.01 || hit.t < 1.2 || hit.t > 2.3 { facing = false }
            if abs(asin(f.y) + wallPitchDown) > 0.01 { facing = false }
        }
        expect(facing, "wall cameras face a wall square-on from 1.2 to 2.3 m, pitched 20 degrees down")
        expect(ceilingViews.allSatisfy { abs(asin(forward($0.camera).y) - ceilingPitchUp) < 0.01 }, "ceiling cameras look 70 degrees up")
        expect(views.allSatisfy { abs(simd_dot(SIMD3($0.camera.transform.columns.0.x, $0.camera.transform.columns.0.y, $0.camera.transform.columns.0.z), SIMD3(0, 1, 0))) < 1e-4 }, "cameras have no roll")

        // Only where the user walked: keyframes in one corner leave out the far side.
        let corner = plan(walls: walls, floorY: 0, ceilingHeight: 2.4, keyframes: [SIMD3(0.8, 1.4, 0.8), SIMD3(1.5, 1.4, 0.8)])
        expect(!corner.isEmpty && corner.count < views.count, "keyframes in one corner give fewer views (\(corner.count))")
        expect(corner.allSatisfy { distanceToNearest(SIMD2(position($0.camera).x, position($0.camera).z), in: [SIMD2(0.8, 0.8), SIMD2(1.5, 0.8)]) <= maxKeyframeDistance }, "corner views stay near the keyframes")
        expect(plan(walls: walls, floorY: 0, ceilingHeight: 2.4, keyframes: []).isEmpty, "no keyframes, no views")

        // A big room hits the cap and keeps both kinds.
        let big = rectangle(width: 20, depth: 16)
        let bigViews = plan(walls: big, floorY: 0, ceilingHeight: 2.6, keyframes: walkedGrid(width: 20, depth: 16))
        expect(bigViews.count == maxViews, "a big room is capped at \(maxViews) (got \(bigViews.count))")
        expect(bigViews.filter { $0.kind == .ceiling }.count == ceilingShare, "the cap keeps \(ceilingShare) ceiling views")

        // A narrow room (2.2 m wide) pulls the camera in rather than putting it outside.
        let narrow = rectangle(width: 4, depth: 2.2)
        let narrowViews = plan(walls: narrow, floorY: 0, ceilingHeight: 2.4, keyframes: walkedGrid(width: 4, depth: 2.2, inset: 0.6))
        expect(!narrowViews.isEmpty && narrowViews.allSatisfy { isInside(SIMD2(position($0.camera).x, position($0.camera).z), walls: narrow) }, "a narrow room still gets views inside it")

        // Floor height is respected.
        let raised = plan(walls: walls, floorY: -0.3, ceilingHeight: 2.4, keyframes: walked)
        expect(raised.filter { $0.kind == .wall }.allSatisfy { abs(position($0.camera).y - (-0.3 + wallCameraHeight)) < 1e-4 }, "wall cameras follow the floor height")

        failures += SplatViewRenderer.projectionSelfCheck()
        return failures
    }
}
#endif
