import SwiftUI
import simd

/// Which fixture the editor opens on (nil: just open it).
struct FixtureEditorRequest: Identifiable {
    let id = UUID()
    var focus: UUID?
}

/// Review and revise a scan's fixtures: the floor plan on top (tap a marker to select it, drag the selected one to move
/// it, or pick "Add" and tap the plan), the list below grouped by kind with the controls for the selected one. Every
/// change is saved to `fixtures.json` at once. Nothing here needs Apple Intelligence or a photo.
struct FixtureEditorView: View {
    let scan: Scan
    var focus: UUID?
    /// Reports the fixture that was selected when the editor closed, so the 3D preview can pulse it.
    var onClose: (UUID?) -> Void = { _ in }
    /// "Open in photo tour": the editor closes, then the tour opens on that fixture's photo.
    var onOpenTour: (UUID) -> Void = { _ in }

    @Environment(ScanStore.self) private var store
    @Environment(FixtureCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.Key.units) private var unitsRaw = AppSettings.Units.imperial.rawValue

    @State private var plan: FloorPlan?
    @State private var room = FixturePlacement.Room(floorY: 0, ceilingY: FixturePlacement.defaultCeilingHeight, walls: [])
    @State private var roomLabel: String?
    @State private var loaded = false

    @State private var selected: UUID?
    @State private var scrollTarget: UUID?
    @State private var placing: Placing?
    @State private var drag: DragInfo?
    @State private var dragPoint: SIMD2<Float>?
    @State private var undo: Undo?
    @State private var photoFixture: UUID?

    struct Placing: Equatable { var kind: Fixture.Kind; var surface: Fixture.Surface }
    struct DragInfo { var hit: UUID?; var grabbed: UUID?; var grabOffset: SIMD2<Float>; var moving = false }
    struct Undo: Equatable { var fixture: Fixture; var index: Int }

    private var units: AppSettings.Units { AppSettings.Units(rawValue: unitsRaw) ?? .imperial }
    private var formatter: RoomSummaryFormatter { RoomSummaryFormatter(units: units) }
    private var library: FixtureLibrary { coordinator.library(for: scan.id) ?? FixtureLibrary() }
    private var fixtures: [Fixture] { library.fixtures }
    /// What the plan draws: the fixture being dragged follows the finger (and snaps live).
    private var shown: [Fixture] {
        guard let id = drag?.grabbed, drag?.moving == true, let p = dragPoint else { return fixtures }
        return fixtures.map { $0.id == id ? FixturePlacement.moved($0, to: p, room: room) : $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                planCard
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                actionBar
                list
            }
            .background(Theme.background)
            .overlay(alignment: .bottom) { toast }
            .navigationTitle("Fixtures")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { close() } }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task { await load() }
        .sheet(isPresented: Binding(get: { photoFixture != nil }, set: { if !$0 { photoFixture = nil } })) {
            if let f = fixtures.first(where: { $0.id == photoFixture }) {
                FixturePhotoSheet(fixture: f, framesURL: store.framesURL(for: scan)) {
                    let id = f.id
                    photoFixture = nil
                    close(openingTourOn: id)
                }
            }
        }
    }

    private var subtitle: String {
        let n = fixtures.count
        guard n > 0 else { return "None yet" }
        let check = library.uncheckedCount
        return "\(n) \(n == 1 ? "fixture" : "fixtures")" + (check > 0 ? " · \(check) to check" : "")
    }

    private func close(openingTourOn id: UUID? = nil) {
        onClose(selected)
        dismiss()
        if let id { onOpenTour(id) }
    }

    // MARK: Plan

    @ViewBuilder private var planCard: some View {
        if let plan, !plan.walls.isEmpty {
            GeometryReader { geo in
                let t = PlanTransform(plan: plan, spots: [], size: geo.size, padding: 30)
                Canvas { ctx, _ in
                    FloorPlanCanvas.drawBase(&ctx, plan: plan, t)
                    FixtureMarker.draw(&ctx, fixtures: shown, point: t.point, pointsPerMetre: t.scale, radius: 11,
                                       backdrop: Theme.tile, selected: selected, markUnchecked: true)
                }
                .contentShape(Rectangle())
                .gesture(planGesture(t))
            }
            .frame(height: 250)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay {
                if placing != nil {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel("Floor plan with \(fixtures.count) \(fixtures.count == 1 ? "fixture" : "fixtures")")
            .accessibilityHint("Select a fixture here, then edit it in the list below")
            .accessibilityActions {
                ForEach(fixtures) { f in
                    Button("Select \(f.accessibilityTitle)") { select(f.id, scroll: true) }
                }
            }
        } else {
            Text(loaded ? "This scan has no floor plan, so fixtures can't be placed on one. You can still review them below."
                         : " ")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .padding(.horizontal, 20)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        }
    }

    /// Replaces the buttons while a new fixture waits for a tap on the plan.
    private func placingBar(_ p: Placing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.kind.symbol).foregroundStyle(p.kind.color()).accessibilityHidden(true)
            Text("Tap the plan where the \(p.kind.sentenceTitle) is")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel") { placing = nil }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Theme.featured, in: Capsule())
        }
        .frame(minHeight: 44)
    }

    private func planGesture(_ t: PlanTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    let hit = placing == nil
                        ? FixtureMarker.hit(at: v.startLocation, fixtures: fixtures, point: t.point, reach: 26,
                                            pointsPerMetre: t.scale)
                        : nil
                    // Only the already selected marker can be dragged; a touch on another one just selects it.
                    let grabbed = hit.flatMap { $0.id == selected ? $0 : nil }
                    drag = DragInfo(hit: hit?.id, grabbed: grabbed?.id,
                                    grabOffset: grabbed.map { $0.planPosition - t.plan(v.startLocation) } ?? .zero)
                }
                guard var d = drag, d.grabbed != nil else { return }
                if !d.moving, hypot(v.translation.width, v.translation.height) < 4 { return }
                if !d.moving { UISelectionFeedbackGenerator().selectionChanged() }
                d.moving = true
                drag = d
                dragPoint = t.plan(v.location) + d.grabOffset
            }
            .onEnded { v in
                defer { drag = nil; dragPoint = nil }
                guard let d = drag else { return }
                if d.moving, let id = d.grabbed, let p = dragPoint {
                    coordinator.move(id, to: p, room: room, scan: scan)
                    return
                }
                if let placing {
                    place(placing, at: t.plan(v.location))
                } else if let id = d.hit {
                    select(id, scroll: true)
                } else {
                    withAnimation(.snappy(duration: 0.2)) { selected = nil }
                }
            }
    }

    private func place(_ p: Placing, at point: SIMD2<Float>) {
        let f = coordinator.add(kind: p.kind, surface: p.surface, at: point, room: room, scan: scan)
        placing = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        select(f.id, scroll: true)
    }

    private func select(_ id: UUID, scroll: Bool = false) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.25)) { selected = id }
        if scroll { scrollTarget = id }
    }

    // MARK: Action bar

    private var actionBar: some View {
        Group {
            if let placing { placingBar(placing) } else { buttons }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Menu {
                FixtureKindMenuItems { kind, surface in
                    selected = nil
                    placing = Placing(kind: kind, surface: surface)
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tile)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(plan?.walls.isEmpty ?? true)
            .opacity((plan?.walls.isEmpty ?? true) ? 0.45 : 1)
            .accessibilityLabel("Add fixture")
            .accessibilityHint("Pick a kind, then tap the plan where it is")
            Spacer()
            if library.uncheckedCount > 0 {
                Button {
                    let n = coordinator.confirmAll(scan: scan)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(notification: .announcement, argument: "\(n) fixtures confirmed")
                } label: {
                    Label("Confirm all \(library.uncheckedCount)", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Theme.featured, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Confirm all \(library.uncheckedCount) unchecked fixtures")
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if fixtures.isEmpty && loaded {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No fixtures yet").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            Text("Tap Add, pick a kind, then tap the plan where it is. Vents, bathroom fans and baseboard heaters can all be added by hand.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    }
                    // One flat ForEach: a fixture that changes kind moves between sections without stale rows.
                    ForEach(listItems) { item in
                        switch item {
                        case let .header(kind, count): sectionHeader(kind, count: count)
                        case let .row(f): row(f)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 90)   // clear of the undo toast
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id.uuidString, anchor: .center) }
                scrollTarget = nil
            }
        }
    }

    private enum ListItem: Identifiable {
        case header(Fixture.Kind, Int)
        case row(Fixture)
        var id: String {
            switch self {
            case let .header(kind, _): "header-\(kind.rawValue)"
            case let .row(f): f.id.uuidString
            }
        }
    }

    private var listItems: [ListItem] {
        Fixture.Kind.allCases.flatMap { kind -> [ListItem] in
            let group = fixtures.filter { $0.kind == kind }
            return group.isEmpty ? [] : [.header(kind, group.count)] + group.map { .row($0) }
        }
    }

    private func sectionHeader(_ kind: Fixture.Kind, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(kind.color())
                .accessibilityHidden(true)
            Text(count == 1 ? kind.title : kind.pluralTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if kind == .baseboardHeater, library.heaterLength > 0 {
                Text("· \(formatter.length(library.heaterLength)) total")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(count == 1 ? kind.title : kind.pluralTitle)")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ f: Fixture) -> some View {
        FixtureEditorRow(
            fixture: f,
            isSelected: selected == f.id,
            location: locationText(f),
            formatter: formatter,
            framesURL: store.framesURL(for: scan),
            onSelect: { if selected == f.id { withAnimation(.snappy(duration: 0.25)) { selected = nil } } else { select(f.id) } },
            onKind: { kind in
                coordinator.setKind(kind, surface: f.surface, for: f.id, room: room, scan: scan)
                scrollTarget = f.id   // the row moves to its new section
            },
            onSurface: { coordinator.setKind(f.kind, surface: $0, for: f.id, room: room, scan: scan) },
            onLength: { coordinator.setLength($0, for: f.id, scan: scan) },
            onConfirm: {
                coordinator.confirm(f.id, scan: scan)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            },
            onPhoto: { photoFixture = f.id },
            onDelete: { delete(f) },
            onNudge: { dx, dz in
                coordinator.move(f.id, to: f.planPosition + SIMD2(dx, dz), room: room, scan: scan)
            })
    }

    /// "Wall · living room · near the sofa". The room name is only known when the scan is a single room.
    private func locationText(_ f: Fixture) -> String {
        var parts = [f.surface.title]
        if let roomLabel { parts.append(roomLabel) }
        if let plan,
           let near = plan.objects.map({ ($0, simd_distance($0.center, f.planPosition)) }).filter({ $0.1 < 1.2 }).min(by: { $0.1 < $1.1 }) {
            parts.append("near the \(near.0.label)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Delete and undo

    private func delete(_ f: Fixture) {
        guard let removed = coordinator.delete(f.id, scan: scan) else { return }
        if selected == f.id { selected = nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.25)) { undo = Undo(fixture: removed.fixture, index: removed.index) }
        UIAccessibility.post(notification: .announcement, argument: "\(f.kind.title) deleted. Undo is available.")
    }

    @ViewBuilder private var toast: some View {
        if let undo {
            HStack(spacing: 12) {
                Text("Deleted \(undo.fixture.kind.sentenceTitle)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Button("Undo") {
                    coordinator.restore(undo.fixture, at: undo.index, scan: scan)
                    self.undo = nil
                    select(undo.fixture.id, scroll: true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo) {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { withAnimation(.snappy(duration: 0.25)) { self.undo = nil } }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        coordinator.load(scan, store: store)
        let planURL = store.floorPlanURL(for: scan)
        let factsURL = store.roomFactsURL(for: scan)
        let result: (FloorPlan?, RoomFacts?) = await Task.detached {
            (planURL.flatMap { FloorPlan.load(from: $0) }, factsURL.flatMap { RoomFacts.load(from: $0) })
        }.value
        plan = result.0
        let floorY = result.0?.floorY ?? 0
        let height = result.1.map(\.averageCeiling).flatMap { $0 > 1.5 ? $0 : nil } ?? FixturePlacement.defaultCeilingHeight
        room = FixturePlacement.Room(floorY: floorY, ceilingY: floorY + height, walls: result.0?.walls ?? [])
        if let rooms = result.1?.rooms, rooms.count == 1 {
            let label = rooms[0].label
            roomLabel = label.prefix(1).uppercased() + label.dropFirst()
        }
        loaded = true
        if let focus, fixtures.contains(where: { $0.id == focus }) {
            selected = focus
            try? await Task.sleep(for: .milliseconds(350))
            scrollTarget = focus
        }
    }
}

// MARK: - Row

private struct FixtureEditorRow: View {
    let fixture: Fixture
    let isSelected: Bool
    let location: String
    let formatter: RoomSummaryFormatter
    let framesURL: URL?
    let onSelect: () -> Void
    let onKind: (Fixture.Kind) -> Void
    let onSurface: (Fixture.Surface) -> Void
    let onLength: (Float?) -> Void
    let onConfirm: () -> Void
    let onPhoto: () -> Void
    let onDelete: () -> Void
    let onNudge: (Float, Float) -> Void

    private var title: String {
        if fixture.kind == .baseboardHeater, let length = fixture.length {
            return "\(fixture.kind.title) · \(formatter.length(length))"
        }
        return fixture.kind.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onSelect) { header }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(headerLabel)
                .accessibilityHint(isSelected ? "Collapses the controls" : "Shows the controls")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityActions {
                    if fixture.needsCheck { Button("Confirm", action: onConfirm) }
                    Button("Delete", role: .destructive, action: onDelete)
                    if isSelected {
                        Button("Move left 10 centimetres") { onNudge(-0.1, 0) }
                        Button("Move right 10 centimetres") { onNudge(0.1, 0) }
                        Button("Move up the plan 10 centimetres") { onNudge(0, -0.1) }
                        Button("Move down the plan 10 centimetres") { onNudge(0, 0.1) }
                    }
                }
            if isSelected { controls }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(isSelected ? fixture.kind.color().opacity(0.8) : .clear, lineWidth: 1.5)
        }
    }

    private var headerLabel: String {
        var s = "\(title), \(location)"
        if fixture.needsCheck { s += ", detected, not checked" }
        return s
    }

    private var header: some View {
        HStack(spacing: 12) {
            FixtureThumbnail(fixture: fixture, framesURL: framesURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(location)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                if fixture.needsCheck {
                    HStack(spacing: 5) {
                        Circle().fill(fixture.kind.color()).frame(width: 6, height: 6)
                        Text("Detected, not checked")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .rotationEffect(.degrees(isSelected ? 180 : 0))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Kind", selection: Binding(get: { fixture.kind }, set: onKind)) {
                ForEach(Fixture.Kind.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)

            if fixture.kind.allowedSurfaces.count > 1 {
                Picker("Mounted on", selection: Binding(get: { fixture.surface }, set: onSurface)) {
                    ForEach(fixture.kind.allowedSurfaces, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if fixture.kind == .baseboardHeater { lengthControl }

            HStack(spacing: 10) {
                if fixture.needsCheck {
                    Button(action: onConfirm) { Label("Confirm", systemImage: "checkmark") }
                        .buttonStyle(FixtureButtonStyle(prominent: true))
                } else {
                    Label(fixture.source == .manual && !fixture.edited ? "Added by you" : "Checked",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accentText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                if fixture.photoFrame != nil {
                    Button(action: onPhoto) { Label("View photo", systemImage: "photo") }
                        .buttonStyle(FixtureButtonStyle(prominent: false))
                }
            }

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableStyle())
        }
        .transition(.opacity)
    }

    private var lengthControl: some View {
        let step: Float = formatter.imperial ? 0.1524 : 0.1       // 6 inches or 10 cm
        return HStack(spacing: 8) {
            Text("Length").font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let length = fixture.length {
                stepButton("minus", label: "Shorter") { onLength(max(0.2, length - step)) }
                Text(formatter.length(length))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 72)
                    .accessibilityLabel("Length \(formatter.length(length))")
                stepButton("plus", label: "Longer") { onLength(min(8, length + step)) }
            } else {
                Button("Set length") { onLength(formatter.imperial ? 0.9144 : 1.0) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 44, height: 44)
                .background(Theme.featured, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Photo thumbnail when the fixture has a frame; otherwise its kind symbol on a tinted tile.
private struct FixtureThumbnail: View {
    let fixture: Fixture
    let framesURL: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                fixture.kind.color().opacity(0.16)
                Image(systemName: fixture.kind.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(fixture.kind.color())
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
        .task(id: fixture.photoFrame) {
            guard let frame = fixture.photoFrame, let framesURL else { image = nil; return }
            image = await TourImageLoader.load(framesURL.appendingPathComponent(frame), maxPixel: 180)
        }
    }
}

/// "View photo": the keyframe with the fixture's box pulsing, and a way on to the photo tour.
private struct FixturePhotoSheet: View {
    let fixture: Fixture
    let framesURL: URL?
    let onOpenTour: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(fixture.kind.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .foregroundStyle(Theme.accentText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            FixturePhotoView(fixture: fixture, framesURL: framesURL, pulse: true)
                .frame(maxHeight: .infinity)
            Button(action: onOpenTour) { Label("Open in photo tour", systemImage: "photo.on.rectangle.angled") }
                .buttonStyle(FixtureButtonStyle(prominent: false))
        }
        .padding(20)
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
