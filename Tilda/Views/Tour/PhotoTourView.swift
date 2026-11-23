import SwiftUI

/// Full-screen tour: floor plan with photo-spot pins on top, swipeable portrait photos below.
struct PhotoTourView: View {
    let scan: Scan
    @Environment(ScanStore.self) private var store
    @Environment(FixtureCoordinator.self) private var fixtureCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var spots: [PhotoSpot] = []
    @State private var plan: FloorPlan?
    @State private var selected = 0
    @State private var loaded = false
    @State private var ceilingHeight: Float?
    @State private var shownFixture: UUID?

    private var fixtures: [Fixture] { fixtureCoordinator.fixtures(for: scan.id) }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            if !loaded {
                Spacer()
                ProgressView().tint(Theme.accent)
                Spacer()
            } else if spots.isEmpty {
                Spacer()
                Text("No photos in this scan")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            } else {
                if let plan {
                    FloorPlanCanvas(plan: plan, spots: spots, selected: $selected, fixtures: fixtures,
                                    selectedFixture: $shownFixture)
                        .frame(height: 250)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                        .accessibilityActions {
                            ForEach(fixtures) { f in
                                Button("Show \(f.kind.title.lowercased()), \(f.surface.rawValue)") { shownFixture = f.id }
                            }
                        }
                        .padding(.horizontal, 16)
                    if !fixtures.isEmpty { FixtureTourLegend(fixtures: fixtures).padding(.horizontal, 20) }
                }
                pager
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await load() }
        .sheet(isPresented: Binding(get: { shownFixture != nil }, set: { if !$0 { shownFixture = nil } })) {
            if let fixture = fixtures.first(where: { $0.id == shownFixture }) {
                FixtureDetailSheet(fixture: fixture, framesURL: store.framesURL(for: scan)) {
                    fixtureCoordinator.delete(fixture.id, scan: scan, store: store)
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            Text("Photo tour")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var pager: some View {
        TabView(selection: $selected) {
            ForEach(spots) { spot in
                TourPhotoPage(spot: spot, isNear: abs(spot.id - selected) <= 1,
                              fixtures: fixtures.filter { $0.photoFrame == spot.frameFile && $0.photoBox != nil },
                              onSelect: { shownFixture = $0.id },
                              onAdd: { kind, surface in add(kind, surface, at: spot) })
                    .tag(spot.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            Text("\(selected + 1) of \(spots.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 14)
                .accessibilityLabel("Photo \(selected + 1) of \(spots.count)")
        }
        .padding(.bottom, 8)
    }

    private func add(_ kind: Fixture.Kind, _ surface: Fixture.Surface, at spot: PhotoSpot) {
        let fixture = fixtureCoordinator.addManual(kind: kind, surface: surface, spot: spot, plan: plan,
                                                   ceilingHeight: ceilingHeight, scan: scan, store: store)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        shownFixture = fixture.id
    }

    private func load() async {
        let framesURL = store.framesURL(for: scan)
        let planURL = store.floorPlanURL(for: scan)
        let factsURL = store.roomFactsURL(for: scan)
        let result: ([PhotoSpot], FloorPlan?, Float?) = await Task.detached {
            guard let framesURL, let manifest = FrameRecorder.load(from: framesURL) else { return ([], nil, nil) }
            let height = factsURL.flatMap { RoomFacts.load(from: $0) }?.averageCeiling
            return (TourModel.spots(from: manifest, framesDir: framesURL),
                    planURL.flatMap { FloorPlan.load(from: $0) }, height.flatMap { $0 > 1.5 ? $0 : nil })
        }.value
        spots = result.0
        plan = result.1
        ceilingHeight = result.2
        fixtureCoordinator.load(scan, store: store)
        loaded = true
    }
}

private struct TourPhotoPage: View {
    let spot: PhotoSpot
    let isNear: Bool
    let fixtures: [Fixture]
    let onSelect: (Fixture) -> Void
    let onAdd: (Fixture.Kind, Fixture.Surface) -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { FixtureBoxesOverlay(fixtures: fixtures, onSelect: onSelect) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                    .accessibilityLabel("Photo \(spot.id + 1)")
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.card)
                if isNear { ProgressView().tint(Theme.accent) }
            }
        }
        .overlay(alignment: .topTrailing) { AddFixtureMenu(onAdd: onAdd).padding(10) }
        .padding(.horizontal, 16)
        .task(id: isNear) {
            if isNear {
                if image == nil { image = await TourImageLoader.load(spot.imageURL) }
            } else {
                image = nil   // release memory for pages the user is not near
            }
        }
    }
}
