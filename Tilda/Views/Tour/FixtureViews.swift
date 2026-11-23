import SwiftUI

/// Maps a box saved in sensor fractions onto the photo tour's display, where the landscape sensor image is shown
/// turned 90 degrees clockwise (`.right`).
extension NormalizedBox {
    var displayedRight: CGRect {
        CGRect(x: CGFloat(1 - (y + height)), y: CGFloat(x), width: CGFloat(height), height: CGFloat(width))
    }
}

/// "Add fixture" button on a tour photo. Hand tagging works with or without Apple Intelligence.
struct AddFixtureMenu: View {
    let onAdd: (Fixture.Kind, Fixture.Surface) -> Void

    var body: some View {
        Menu {
            Menu {
                surfaceButtons(.hvacVent, [.wall, .ceiling, .floor])
            } label: { Label(Fixture.Kind.hvacVent.title, systemImage: Fixture.Kind.hvacVent.symbol) }
            Menu {
                surfaceButtons(.bathroomFan, [.ceiling, .wall])
            } label: { Label(Fixture.Kind.bathroomFan.title, systemImage: Fixture.Kind.bathroomFan.symbol) }
            Button { onAdd(.baseboardHeater, .wall) } label: {
                Label(Fixture.Kind.baseboardHeater.title, systemImage: Fixture.Kind.baseboardHeater.symbol)
            }
        } label: {
            Label("Add fixture", systemImage: "plus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .accessibilityHint("Marks a vent, fan or heater on the plan near this photo")
    }

    private func surfaceButtons(_ kind: Fixture.Kind, _ surfaces: [Fixture.Surface]) -> some View {
        ForEach(surfaces, id: \.self) { surface in
            Button(surface == .ceiling ? "In the ceiling" : surface == .floor ? "On the floor" : "On a wall") {
                onAdd(kind, surface)
            }
        }
    }
}

/// Outlines of fixtures the model found in this photo. Tap one to open it.
struct FixtureBoxesOverlay: View {
    let fixtures: [Fixture]
    let onSelect: (Fixture) -> Void

    var body: some View {
        GeometryReader { geo in
            ForEach(fixtures) { f in
                if let box = f.photoBox?.displayedRight {
                    let rect = CGRect(x: box.minX * geo.size.width, y: box.minY * geo.size.height,
                                      width: box.width * geo.size.width, height: box.height * geo.size.height)
                    Button { onSelect(f) } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(f.kind.color(), lineWidth: 2.5)
                            .background(f.kind.color().opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: max(rect.width, 44), height: max(rect.height, 44))
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityLabel(f.accessibilityTitle)
                    .accessibilityHint("Shows details")
                }
            }
        }
    }
}

/// Photo, details and a remove button for one fixture.
struct FixtureDetailSheet: View {
    let fixture: Fixture
    let framesURL: URL?
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.units) private var unitsRaw = AppSettings.Units.imperial.rawValue
    @State private var image: UIImage?
    @State private var confirmDelete = false

    private var formatter: RoomSummaryFormatter {
        RoomSummaryFormatter(units: AppSettings.Units(rawValue: unitsRaw) ?? .imperial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                photo
                details
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Remove fixture", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .confirmationDialog("Remove this \(fixture.kind.title.lowercased())?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { onDelete(); dismiss() }
            Button("Keep", role: .cancel) {}
        }
        .task(id: fixture.photoFrame) {
            guard let frame = fixture.photoFrame, let framesURL else { return }
            image = await TourImageLoader.load(framesURL.appendingPathComponent(frame))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: fixture.kind.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(fixture.kind.color())
                .frame(width: 48, height: 48)
                .background(fixture.kind.color().opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.kind.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(fixture.placementText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var photo: some View {
        if fixture.photoFrame != nil {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            if let box = fixture.photoBox?.displayedRight {
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(fixture.kind.color(), lineWidth: 3)
                                        .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                                        .position(x: box.midX * geo.size.width, y: box.midY * geo.size.height)
                                }
                                .accessibilityHidden(true)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                        .accessibilityLabel("Photo showing the \(fixture.kind.title.lowercased())")
                } else {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.card)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay { ProgressView().tint(Theme.accent) }
                }
            }
            .frame(maxHeight: 420)
            .frame(maxWidth: .infinity)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let length = fixture.length { row("Length", formatter.length(length)) }
            switch fixture.source {
            case .manual:
                row("Source", "Added by you")
            case .detected:
                row("Source", "Found in the scan photos")
                if let c = fixture.confidence { row("Confidence", "\(Int((c * 100).rounded()))%") }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// Counts under the tour plan, doubling as the marker legend.
struct FixtureTourLegend: View {
    let fixtures: [Fixture]

    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(Fixture.Kind.allCases, id: \.self) { kind in
                let n = fixtures.filter { $0.kind == kind }.count
                if n > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(kind.color())
                            .accessibilityHidden(true)
                        Text("\(n) \(n == 1 ? kind.title.lowercased() : kind.pluralTitle.lowercased())")
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
