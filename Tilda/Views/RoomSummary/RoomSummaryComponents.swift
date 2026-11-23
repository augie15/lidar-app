import SwiftUI
import simd

// MARK: - Palette (dark app theme, light print theme)

struct SummaryPalette {
    var background: Color
    var card: Color
    var hero: Color
    var accent: Color
    var accentText: Color
    var primary: Color
    var secondary: Color
    var muted: Color
    var separator: Color

    static let dark = SummaryPalette(
        background: Theme.background, card: Theme.card, hero: Theme.featured, accent: Theme.accent,
        accentText: Theme.accentText, primary: Theme.textPrimary, secondary: Theme.textSecondary,
        muted: Theme.textMuted, separator: Theme.separator)

    static let light = SummaryPalette(
        background: .white, card: Color(red: 0.96, green: 0.97, blue: 0.965),
        hero: Color(red: 0.89, green: 0.96, blue: 0.93), accent: Color(red: 0.12, green: 0.55, blue: 0.42),
        accentText: Color(red: 0.06, green: 0.40, blue: 0.30), primary: Color(red: 0.07, green: 0.09, blue: 0.08),
        secondary: Color(red: 0.30, green: 0.33, blue: 0.32), muted: Color(red: 0.38, green: 0.41, blue: 0.40),
        separator: Color.black.opacity(0.12))
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = SummaryPalette.dark }
extension EnvironmentValues {
    var summaryPalette: SummaryPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Hero

struct SummaryHero: View {
    let facts: RoomFacts
    let units: AppSettings.Units
    @Environment(\.summaryPalette) private var p
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize: CGFloat = 76

    var body: some View {
        let f = RoomSummaryFormatter(units: units)
        let total = facts.totalFloorArea
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total floor area")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(p.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(f.areaNumber(total))
                        .font(.system(size: bigSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(p.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(f.areaUnit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(p.accentText)
                }
                Text(f.altArea(total))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(p.secondary)
            }
            .accessibilityElement(children: .combine)

            if facts.totalOpenFloorArea != nil || facts.totalGrossArea != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 0) {
                        if let open = facts.totalOpenFloorArea { stat(f.area(open), "Open floor") }
                        if let gross = facts.totalGrossArea { stat(f.area(gross), "Est. gross") }
                    }
                    if facts.totalOpenFloorArea != nil {
                        Text("Open floor: Floor not covered by furniture.").footnote(p)
                    }
                    if facts.totalGrossArea != nil {
                        Text("Est. gross: Adds wall thickness, like listing square footage (assumes \(f.wallThickness(facts.wallThickness)) walls).").footnote(p)
                    }
                }
            }

            Rectangle().fill(p.separator).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                stat("\(facts.rooms.count)", facts.rooms.count == 1 ? "Room" : "Rooms")
                stat(f.length(facts.averageCeiling), "Avg ceiling")
                stat("\(facts.totalDoors)", facts.totalDoors == 1 ? "Door" : "Doors")
                stat("\(facts.totalWindows)", facts.totalWindows == 1 ? "Window" : "Windows")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.hero, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(p.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(p.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension Text {
    func footnote(_ p: SummaryPalette) -> some View {
        font(.caption2).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Mini floor plan

struct SummaryPlan: View {
    let plan: FloorPlan
    @Environment(\.summaryPalette) private var p

    private var aspect: CGFloat {
        let (lo, hi) = plan.bounds
        let w = CGFloat(max(hi.x - lo.x, 0.5)), h = CGFloat(max(hi.y - lo.y, 0.5))
        return min(max(w / h, 0.7), 2.4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Canvas { ctx, size in draw(&ctx, size) }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 260)
                .accessibilityElement()
                .accessibilityLabel("Floor plan with \(plan.walls.count) walls, \(plan.doors.count) doors and \(plan.windows.count) windows")
            HStack(spacing: 16) {
                legend(p.accent, "Door")
                legend(p.accentText, "Window")
                legend(p.muted, "Opening")
            }
            .font(.caption)
            .foregroundStyle(p.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(title)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let (lo, hi) = plan.bounds
        let pad: CGFloat = 8
        let w = CGFloat(max(hi.x - lo.x, 0.5)), h = CGFloat(max(hi.y - lo.y, 0.5))
        let scale = min((size.width - pad * 2) / w, (size.height - pad * 2) / h)
        let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2
        func pt(_ v: SIMD2<Float>) -> CGPoint {
            CGPoint(x: ox + CGFloat(v.x - lo.x) * scale, y: oy + CGFloat(v.y - lo.y) * scale)
        }
        func line(_ s: FloorPlan.Segment) -> Path {
            var path = Path(); path.move(to: pt(s.start)); path.addLine(to: pt(s.end)); return path
        }

        for box in plan.objects {
            let c = pt(box.center)
            let bw = CGFloat(box.size.x) * scale, bd = CGFloat(box.size.y) * scale
            var layer = ctx
            layer.translateBy(x: c.x, y: c.y)
            layer.rotate(by: .radians(Double(box.rotation)))
            let path = Path(roundedRect: CGRect(x: -bw / 2, y: -bd / 2, width: bw, height: bd),
                            cornerRadius: min(3, min(bw, bd) / 3), style: .continuous)
            layer.fill(path, with: .color(p.accent.opacity(0.12)))
            layer.stroke(path, with: .color(p.accent.opacity(0.35)), lineWidth: 0.75)
        }
        let wall = StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
        for s in plan.walls { ctx.stroke(line(s), with: .color(p.secondary), style: wall) }
        func gap(_ s: FloorPlan.Segment, _ color: Color, _ width: CGFloat, dash: [CGFloat] = []) {
            ctx.stroke(line(s), with: .color(p.card), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
            ctx.stroke(line(s), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: dash.isEmpty ? .round : .butt, dash: dash))
        }
        for s in plan.openings { gap(s, p.muted, 1.5, dash: [3, 3]) }
        for s in plan.windows { gap(s, p.accentText, 2) }
        for s in plan.doors { gap(s, p.accent, 3.5) }
    }
}

// MARK: - Room card

struct SummaryRoomCard: View {
    let room: RoomFacts.Room
    let units: AppSettings.Units
    @Environment(\.summaryPalette) private var p

    var body: some View {
        let f = RoomSummaryFormatter(units: units)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(room.displayLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(p.primary)
                    Spacer(minLength: 12)
                    Text(f.area(room.floorArea))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(p.accentText)
                }
                if let dims = f.dimensions(for: room) {
                    Text("Approx. \(dims)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(p.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    fact("Perimeter", f.length(room.perimeter))
                    fact("Ceiling", f.length(room.ceilingHeight))
                    fact("Wall area", f.area(room.wallArea))
                }
                if room.openFloorArea != nil || room.grossArea != nil {
                    GridRow {
                        if let open = room.openFloorArea { fact("Open floor", f.area(open)) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        if let gross = room.grossArea { fact("Gross (est.)", f.area(gross)) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                GridRow {
                    fact("Doors", "\(room.doorCount)")
                    fact("Windows", "\(room.windowCount)")
                    fact("Openings", "\(room.openingCount)")
                }
            }

            let groups = room.furnitureGroups
            if !groups.isEmpty {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Furniture").font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
                    ForEach(groups, id: \.name) { g in
                        HStack {
                            Text(g.name).foregroundStyle(p.secondary)
                            Spacer()
                            Text("× \(g.count)").monospacedDigit().foregroundStyle(p.primary)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            divider
            VStack(alignment: .leading, spacing: 10) {
                Text("Estimates").font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
                estimate("Paint", "2 coats", f.paint(wallArea: room.wallArea))
                estimate("Flooring", "+10% waste", f.area(f.flooringArea(room.floorArea)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    private var divider: some View { Rectangle().fill(p.separator).frame(height: 1) }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(p.primary)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(title).font(.caption).foregroundStyle(p.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func estimate(_ title: String, _ note: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(p.primary)
                Text(note).font(.caption).foregroundStyle(p.secondary)
            }
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(p.accentText).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
