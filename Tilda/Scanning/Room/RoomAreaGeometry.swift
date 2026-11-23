import Foundation
import simd

/// Pure 2D geometry behind open floor area and estimated gross area. No RoomPlan types, so it can be unit tested
/// from a plain Swift script. All coordinates are world x/z metres, held as SIMD2 (x, z).
enum RoomAreaGeometry {

    // MARK: Open floor area

    /// An oriented rectangle on the floor: centre, two unit axes and half extents along each.
    struct Footprint {
        var center: SIMD2<Float>
        var axisU: SIMD2<Float>
        var axisV: SIMD2<Float>
        var halfU: Float
        var halfV: Float

        /// Footprint from a yaw (radians about +y) and full x by z dimensions.
        init(center: SIMD2<Float>, yaw: Float, sizeX: Float, sizeZ: Float) {
            self.center = center
            axisU = SIMD2(cos(yaw), -sin(yaw))
            axisV = SIMD2(sin(yaw), cos(yaw))
            halfU = sizeX / 2
            halfV = sizeZ / 2
        }

        /// Footprint from a world transform's x and z axes projected onto the floor plane.
        init(transform m: simd_float4x4, sizeX: Float, sizeZ: Float) {
            center = SIMD2(m.columns.3.x, m.columns.3.z)
            let u = SIMD2(m.columns.0.x, m.columns.0.z), v = SIMD2(m.columns.2.x, m.columns.2.z)
            let ul = simd_length(u), vl = simd_length(v)
            axisU = ul > 1e-4 ? u / ul : SIMD2(1, 0)
            axisV = vl > 1e-4 ? v / vl : SIMD2(0, 1)
            halfU = sizeX / 2
            halfV = sizeZ / 2
        }

        func contains(_ p: SIMD2<Float>) -> Bool {
            let d = p - center
            return abs(simd_dot(d, axisU)) <= halfU && abs(simd_dot(d, axisV)) <= halfV
        }

        var bounds: (lo: SIMD2<Float>, hi: SIMD2<Float>) {
            let ex = abs(axisU.x) * halfU + abs(axisV.x) * halfV
            let ez = abs(axisU.y) * halfU + abs(axisV.y) * halfV
            return (center - SIMD2(ex, ez), center + SIMD2(ex, ez))
        }
    }

    /// Rasterises the floor polygons on a `cell` metre grid (cell centres sampled). Returns the floor area and the
    /// open area (floor minus the union of footprints) as cell counts times cell area. Overlapping footprints count once.
    static func rasterize(polygons: [[SIMD2<Float>]], footprints: [Footprint],
                          cell: Float = 0.03) -> (floor: Float, open: Float) {
        let usable = polygons.filter { $0.count >= 3 }
        guard !usable.isEmpty, cell > 0 else { return (0, 0) }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in usable.joined() { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let nx = Int(((hi.x - lo.x) / cell).rounded(.up)), nz = Int(((hi.y - lo.y) / cell).rounded(.up))
        guard nx > 0, nz > 0, nx * nz <= 40_000_000 else { return (0, 0) }
        // Only the footprints that can touch the floor bounds matter.
        let fps = footprints.filter { f in
            let b = f.bounds
            return b.hi.x >= lo.x && b.lo.x <= hi.x && b.hi.y >= lo.y && b.lo.y <= hi.y
        }
        var floorCells = 0, openCells = 0
        for iz in 0..<nz {
            let z = lo.y + (Float(iz) + 0.5) * cell
            for ix in 0..<nx {
                let p = SIMD2(lo.x + (Float(ix) + 0.5) * cell, z)
                guard usable.contains(where: { contains($0, p) }) else { continue }
                floorCells += 1
                if !fps.contains(where: { $0.contains(p) }) { openCells += 1 }
            }
        }
        return (Float(floorCells) * cell * cell, Float(openCells) * cell * cell)
    }

    /// Even-odd point in polygon.
    static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Whether a floor-standing object counts as covering floor: not more than `maxLift` metres above the floor.
    /// `bottom` is transform y minus half the height.
    static func touchesFloor(centerY: Float, height: Float, floorY: Float, maxLift: Float = 0.25) -> Bool {
        (centerY - height / 2) - floorY <= maxLift
    }

    // MARK: Gross area

    struct Wall {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        /// Walls from the same room are never paired with each other. Use a unique value per wall when unknown.
        var room: Int
        var length: Float { simd_distance(a, b) }
    }

    /// Splits wall length into shared (interior, counted once) and exterior.
    ///
    /// A wall is shared when another wall from a different room runs parallel (under 10 degrees), within 0.5 m, and
    /// overlaps by at least 30% of the shorter wall's length. Each pair counts once: its overlap length is interior
    /// wall, and that overlap is removed from both walls' lengths to leave the exterior length.
    static func classify(walls: [Wall]) -> (interior: Float, exterior: Float) {
        let total = walls.reduce(Float(0)) { $0 + $1.length }
        var paired = [Bool](repeating: false, count: walls.count)
        var interior: Float = 0
        var removed: Float = 0
        // A wall pairs with at most one partner (its best overlap), so a wall facing two neighbours isn't double counted.
        var candidates: [(i: Int, j: Int, overlap: Float)] = []
        for i in walls.indices {
            for j in walls.indices where j > i && walls[i].room != walls[j].room {
                if let o = sharedOverlap(walls[i], walls[j]) { candidates.append((i, j, o)) }
            }
        }
        for c in candidates.sorted(by: { $0.overlap > $1.overlap }) where !paired[c.i] && !paired[c.j] {
            paired[c.i] = true; paired[c.j] = true
            interior += c.overlap
            removed += 2 * c.overlap
        }
        return (interior, max(0, total - removed))
    }

    static func sharedOverlap(_ w1: Wall, _ w2: Wall) -> Float? {
        let d1 = w1.b - w1.a, d2 = w2.b - w2.a
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 0.05, l2 > 0.05 else { return nil }
        let u = d1 / l1
        let cosAngle = abs(simd_dot(u, d2 / l2))
        guard cosAngle >= cos(10 * Float.pi / 180) else { return nil }
        // Perpendicular distance of w2's midpoint from w1's line.
        let n = SIMD2(-u.y, u.x)
        let mid2 = (w2.a + w2.b) / 2
        guard abs(simd_dot(mid2 - w1.a, n)) <= 0.5 else { return nil }
        // Overlap along w1's direction.
        let t0 = simd_dot(w2.a - w1.a, u), t1 = simd_dot(w2.b - w1.a, u)
        let overlap = min(l1, max(t0, t1)) - max(0, min(t0, t1))
        guard overlap >= 0.3 * min(l1, l2) else { return nil }
        return overlap
    }

    /// Room gross area: floor plus half the wall thickness all round.
    static func grossArea(floor: Float, perimeter: Float, thickness t: Float) -> Float {
        floor + perimeter * t / 2
    }

    /// Whole scan gross area: sum of floors, shared walls once at thickness t, exterior walls at thickness t, and
    /// 4 t² of corner squares (exact for a simple rectangular outline, a fair estimate otherwise).
    static func totalGrossArea(floors: Float, walls: [Wall], thickness t: Float) -> Float {
        let (interior, exterior) = classify(walls: walls)
        return floors + interior * t + exterior * t + 4 * t * t
    }
}
