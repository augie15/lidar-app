import SwiftUI
import simd

// Visual language for fixtures. The plan is teal and grey, so fixtures get their own warm and cool tints, and each
// kind also has its own marker shape and symbol so they never rely on colour alone:
//   HVAC vent        rounded square, "wind"
//   Bathroom fan     circle, "fan"
//   Baseboard heater capsule on a line along the wall, "heater.vertical"

extension Fixture.Kind {
    var symbol: String {
        switch self {
        case .hvacVent: "wind"
        case .bathroomFan: "fan"
        case .baseboardHeater: "heater.vertical"
        }
    }

    /// Tint on the dark app background, or on the light print page when `light` is true.
    func color(light: Bool = false) -> Color {
        switch (self, light) {
        case (.hvacVent, false): Color(red: 0x7D/255, green: 0xB7/255, blue: 0xF0/255)
        case (.bathroomFan, false): Color(red: 0xF2/255, green: 0xC0/255, blue: 0x63/255)
        case (.baseboardHeater, false): Color(red: 0xF0/255, green: 0x8A/255, blue: 0x6B/255)
        case (.hvacVent, true): Color(red: 0x1F/255, green: 0x6F/255, blue: 0xB8/255)
        case (.bathroomFan, true): Color(red: 0x9A/255, green: 0x5F/255, blue: 0x00/255)
        case (.baseboardHeater, true): Color(red: 0xB8/255, green: 0x3F/255, blue: 0x24/255)
        }
    }
}

extension Fixture {
    /// "On the ceiling", "Along a wall"… for the detail sheet.
    var placementText: String {
        switch surface {
        case .floor: "On the floor"
        case .ceiling: "In the ceiling"
        case .wall: kind == .baseboardHeater ? "Along a wall" : "On a wall"
        }
    }

    var accessibilityTitle: String {
        var s = "\(kind.title), \(surface.rawValue)"
        if source == .manual { s += ", added by you" }
        return s
    }
}

/// Draws fixture markers into a Canvas, on the plan.
enum FixtureMarker {
    /// - Parameters:
    ///   - point: plan metres to canvas points.
    ///   - pointsPerMetre: canvas scale, used to draw heater lengths.
    ///   - radius: half the badge size.
    ///   - backdrop: colour of the surface behind the plan, used for badge outlines and the glyph.
    static func draw(_ ctx: inout GraphicsContext, fixtures: [Fixture], point: (SIMD2<Float>) -> CGPoint,
                     pointsPerMetre: CGFloat, radius: CGFloat, backdrop: Color, light: Bool = false,
                     selected: UUID? = nil, markUnchecked: Bool = false) {
        // Heater runs first, so every badge sits on top of them.
        for f in fixtures where f.kind == .baseboardHeater {
            let c = point(f.planPosition)
            let color = f.kind.color(light: light)
            let axis = f.axis ?? SIMD2(1, 0)
            let half = CGFloat(f.length ?? 0.6) * pointsPerMetre / 2
            var run = Path()
            run.move(to: CGPoint(x: c.x - CGFloat(axis.x) * half, y: c.y - CGFloat(axis.y) * half))
            run.addLine(to: CGPoint(x: c.x + CGFloat(axis.x) * half, y: c.y + CGFloat(axis.y) * half))
            ctx.stroke(run, with: .color(backdrop), style: StrokeStyle(lineWidth: radius * 0.9 + 3, lineCap: .round))
            ctx.stroke(run, with: .color(color), style: StrokeStyle(lineWidth: radius * 0.9, lineCap: .round))
        }
        // Selected last.
        let ordered = fixtures.filter { $0.id != selected } + fixtures.filter { $0.id == selected }
        for f in ordered {
            badge(&ctx, f, at: point(f.planPosition), radius: radius, backdrop: backdrop, light: light,
                  selected: f.id == selected, unchecked: markUnchecked && f.needsCheck)
        }
    }

    private static func badge(_ ctx: inout GraphicsContext, _ f: Fixture, at c: CGPoint, radius r: CGFloat,
                              backdrop: Color, light: Bool, selected: Bool, unchecked: Bool) {
        let color = f.kind.color(light: light)
        let rect: CGRect
        let path: Path
        switch f.kind {
        case .hvacVent:
            rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            path = Path(roundedRect: rect, cornerRadius: r * 0.35, style: .continuous)
        case .bathroomFan:
            rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            path = Path(ellipseIn: rect)
        case .baseboardHeater:
            rect = CGRect(x: c.x - r * 1.5, y: c.y - r * 0.8, width: r * 3, height: r * 1.6)
            path = Path(roundedRect: rect, cornerRadius: r * 0.8, style: .continuous)
        }
        if selected {
            ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3.5))
        } else if unchecked {
            // Dashed outline: detected, not checked yet.
            ctx.stroke(path, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, dash: [3, 3]))
        }
        ctx.fill(path, with: .color(color))
        ctx.stroke(path, with: .color(backdrop), lineWidth: 1.5)
        let glyph = ctx.resolve(Text(Image(systemName: f.kind.symbol))
            .font(.system(size: max(r * 1.05, 8), weight: .bold))
            .foregroundStyle(backdrop))
        ctx.draw(glyph, at: c, anchor: .center)
    }

    /// Nearest fixture to a tap, within `reach` points.
    /// Pass `pointsPerMetre` to let a tap anywhere along a heater's drawn run count.
    static func hit(at location: CGPoint, fixtures: [Fixture], point: (SIMD2<Float>) -> CGPoint,
                    reach: CGFloat = 22, pointsPerMetre: CGFloat = 0) -> Fixture? {
        func distance(_ f: Fixture) -> CGFloat {
            let c = point(f.planPosition)
            guard f.kind == .baseboardHeater, pointsPerMetre > 0 else { return hypot(c.x - location.x, c.y - location.y) }
            let axis = f.axis ?? SIMD2(1, 0)
            let half = CGFloat(f.length ?? 0.6) * pointsPerMetre / 2
            let a = CGPoint(x: c.x - CGFloat(axis.x) * half, y: c.y - CGFloat(axis.y) * half)
            let b = CGPoint(x: c.x + CGFloat(axis.x) * half, y: c.y + CGFloat(axis.y) * half)
            let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let l2 = ab.dx * ab.dx + ab.dy * ab.dy
            let t = l2 > 0 ? min(max(((location.x - a.x) * ab.dx + (location.y - a.y) * ab.dy) / l2, 0), 1) : 0
            return hypot(a.x + ab.dx * t - location.x, a.y + ab.dy * t - location.y)
        }
        return fixtures.map { ($0, distance($0)) }.filter { $0.1 <= reach }.min { $0.1 < $1.1 }?.0
    }
}

/// Small marker + name used in legends.
struct FixtureLegendItem: View {
    let kind: Fixture.Kind
    var light = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(kind.color(light: light))
                .accessibilityHidden(true)
            Text(kind.title)
        }
    }
}

/// Counts per kind, with total heater length. Shared by the on-screen card and the PDF.
struct FixtureCountList: View {
    let library: FixtureLibrary
    let units: AppSettings.Units
    let palette: SummaryPalette

    var body: some View {
        let f = RoomSummaryFormatter(units: units)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Fixture.Kind.allCases, id: \.self) { kind in
                let n = library.count(of: kind)
                HStack(spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(kind.color(light: palette.isLight))
                        .frame(width: 34, height: 34)
                        .background(kind.color(light: palette.isLight).opacity(palette.isLight ? 0.12 : 0.16),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n == 1 ? kind.title : kind.pluralTitle)
                            .font(.subheadline)
                            .foregroundStyle(n == 0 ? palette.secondary : palette.primary)
                        if kind == .baseboardHeater, library.heaterLength > 0 {
                            Text("About \(f.length(library.heaterLength)) in total")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(palette.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(n)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(n == 0 ? palette.muted : palette.accentText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
