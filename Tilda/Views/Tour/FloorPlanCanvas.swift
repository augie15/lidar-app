import SwiftUI
import simd

/// Maps plan metres into a view, fitting everything with padding.
struct PlanTransform {
    let scale: CGFloat
    let origin: CGPoint
    let minPoint: SIMD2<Float>

    init(plan: FloorPlan, spots: [PhotoSpot], size: CGSize, padding: CGFloat = 28) {
        var lo = plan.bounds.0
        var hi = plan.bounds.1
        for s in spots { lo = simd_min(lo, s.position); hi = simd_max(hi, s.position) }
        let w = CGFloat(max(hi.x - lo.x, 0.5))
        let h = CGFloat(max(hi.y - lo.y, 0.5))
        let avail = CGSize(width: max(size.width - padding * 2, 1), height: max(size.height - padding * 2, 1))
        scale = min(avail.width / w, avail.height / h)
        origin = CGPoint(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2)
        minPoint = lo
    }

    func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x - minPoint.x) * scale,
                y: origin.y + CGFloat(p.y - minPoint.y) * scale)
    }
}

/// Top-down plan with tappable photo-spot pins.
struct FloorPlanCanvas: View {
    let plan: FloorPlan
    let spots: [PhotoSpot]
    @Binding var selected: Int

    var body: some View {
        GeometryReader { geo in
            let t = PlanTransform(plan: plan, spots: spots, size: geo.size)
            Canvas { ctx, _ in draw(&ctx, t) }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let id = Self.spotID(at: value.location, spots: spots, selected: selected, point: t.point) {
                            withAnimation(.snappy(duration: 0.25)) { selected = id }
                        }
                    }
                )
        }
        .accessibilityElement()
        .accessibilityLabel("Floor plan with \(spots.count) photo spots")
        .accessibilityValue("Spot \(selected + 1) of \(spots.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selected = min(selected + 1, spots.count - 1)
            case .decrement: selected = max(selected - 1, 0)
            @unknown default: break
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ t: PlanTransform) {
        // Furniture: faint rounded rectangles.
        for box in plan.objects {
            let c = t.point(box.center)
            let w = CGFloat(box.size.x) * t.scale, d = CGFloat(box.size.y) * t.scale
            var layer = ctx
            layer.translateBy(x: c.x, y: c.y)
            layer.rotate(by: .radians(Double(box.rotation)))
            let rect = CGRect(x: -w / 2, y: -d / 2, width: w, height: d)
            let path = Path(roundedRect: rect, cornerRadius: min(4, min(w, d) / 3), style: .continuous)
            layer.fill(path, with: .color(Theme.accent.opacity(0.07)))
            layer.stroke(path, with: .color(Theme.accent.opacity(0.18)), lineWidth: 1)
        }

        func line(_ s: FloorPlan.Segment) -> Path {
            var p = Path()
            p.move(to: t.point(s.start))
            p.addLine(to: t.point(s.end))
            return p
        }

        let wallStyle = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        for s in plan.walls { ctx.stroke(line(s), with: .color(Theme.textSecondary), style: wallStyle) }
        // Openings: dashed gap markers. Windows: thin light line over the wall. Doors: accent.
        for s in plan.openings {
            ctx.stroke(line(s), with: .color(Theme.background), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
            ctx.stroke(line(s), with: .color(Theme.textMuted), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
        for s in plan.windows {
            ctx.stroke(line(s), with: .color(Theme.background), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
            ctx.stroke(line(s), with: .color(Theme.accentText), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
        }
        for s in plan.doors {
            ctx.stroke(line(s), with: .color(Theme.background), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
            ctx.stroke(line(s), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        // Pins: unselected first so the selected pin sits on top.
        for spot in spots where spot.id != selected { drawPin(&ctx, t, spot, active: false) }
        if let spot = spots.first(where: { $0.id == selected }) { drawPin(&ctx, t, spot, active: true) }
    }

    private func drawPin(_ ctx: inout GraphicsContext, _ t: PlanTransform, _ spot: PhotoSpot, active: Bool) {
        let c = t.point(spot.position)
        let r: CGFloat = active ? 6.5 : 4
        if let f = spot.facing {
            let angle = Double(atan2(f.y, f.x))
            let reach: CGFloat = active ? 24 : 15
            let half = 0.5
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: reach, startAngle: .radians(angle - half),
                         endAngle: .radians(angle + half), clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(Theme.accent.opacity(active ? 0.55 : 0.25)))
        }
        let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        if active {
            let halo = Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2))
            ctx.fill(halo, with: .color(Theme.accent.opacity(0.25)))
            ctx.fill(dot, with: .color(Theme.accent))
            ctx.stroke(dot, with: .color(.white), lineWidth: 2)
        } else {
            ctx.fill(dot, with: .color(Theme.accentText.opacity(0.75)))
        }
    }
}

extension FloorPlanCanvas {
    /// Picks the spot for a tap. Several views can share one place (turning on the spot), so pins stack:
    /// a tap on the stack's centre cycles to the next view there, and a tap off-centre picks the view whose
    /// wedge points toward the tap.
    static func spotID(at location: CGPoint, spots: [PhotoSpot], selected: Int,
                       point: (SIMD2<Float>) -> CGPoint) -> Int? {
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let hits = spots.filter { dist(point($0.position), location) <= 32 }
        guard let nearest = hits.min(by: { dist(point($0.position), location) < dist(point($1.position), location) })
        else { return nil }
        // Views stacked on the nearest pin (within a few points on screen).
        let anchor = point(nearest.position)
        let stack = hits.filter { dist(point($0.position), anchor) <= 10 }.sorted { $0.id < $1.id }
        guard stack.count > 1 else { return nearest.id }

        let tap = CGVector(dx: location.x - anchor.x, dy: location.y - anchor.y)
        if hypot(tap.dx, tap.dy) < 8 {
            // Centre tap: step to the next view in this stack.
            let index = stack.firstIndex { $0.id == selected }.map { ($0 + 1) % stack.count } ?? 0
            return stack[index].id
        }
        // Off-centre tap: the view whose on-screen facing best matches the tap direction.
        func screenFacing(_ spot: PhotoSpot) -> CGVector? {
            guard let f = spot.facing else { return nil }
            let a = point(spot.position), b = point(spot.position + f * 0.25)
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let len = hypot(v.dx, v.dy)
            return len > 0 ? CGVector(dx: v.dx / len, dy: v.dy / len) : nil
        }
        let tapLen = hypot(tap.dx, tap.dy)
        return stack.max { a, b in
            let fa = screenFacing(a).map { ($0.dx * tap.dx + $0.dy * tap.dy) / tapLen } ?? -2
            let fb = screenFacing(b).map { ($0.dx * tap.dx + $0.dy * tap.dy) / tapLen } ?? -2
            return fa < fb
        }?.id ?? nearest.id
    }
}
