import SwiftUI

/// Full-screen tour: floor plan with photo-spot pins on top, swipeable portrait photos below.
struct PhotoTourView: View {
    let scan: Scan
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var spots: [PhotoSpot] = []
    @State private var plan: FloorPlan?
    @State private var selected = 0
    @State private var loaded = false

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
                    FloorPlanCanvas(plan: plan, spots: spots, selected: $selected)
                        .frame(height: 250)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                        .padding(.horizontal, 16)
                }
                pager
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await load() }
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
                TourPhotoPage(spot: spot, isNear: abs(spot.id - selected) <= 1)
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

    private func load() async {
        let framesURL = store.framesURL(for: scan)
        let planURL = store.floorPlanURL(for: scan)
        let result: ([PhotoSpot], FloorPlan?) = await Task.detached {
            guard let framesURL, let manifest = FrameRecorder.load(from: framesURL) else { return ([], nil) }
            return (TourModel.spots(from: manifest, framesDir: framesURL),
                    planURL.flatMap { FloorPlan.load(from: $0) })
        }.value
        spots = result.0
        plan = result.1
        loaded = true
    }
}

private struct TourPhotoPage: View {
    let spot: PhotoSpot
    let isNear: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                    .accessibilityLabel("Photo \(spot.id + 1)")
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.card)
                if isNear { ProgressView().tint(Theme.accent) }
            }
        }
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
