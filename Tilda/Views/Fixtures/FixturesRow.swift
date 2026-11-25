import SwiftUI

/// Compact "Fixtures" card on a Room scan's page: one chip per kind with its count (heaters add their total length),
/// how many detections still need a look, and the way into the editor. Shows progress while detection runs and the
/// Find action when nothing has been found yet.
struct FixturesRow: View {
    let scan: Scan
    let onReview: () -> Void

    @Environment(ScanStore.self) private var store
    @Environment(FixtureCoordinator.self) private var coordinator
    @Environment(SplatCoordinator.self) private var splats
    @AppStorage(AppSettings.Key.units) private var unitsRaw = AppSettings.Units.imperial.rawValue

    private var units: AppSettings.Units { AppSettings.Units(rawValue: unitsRaw) ?? .imperial }
    private var library: FixtureLibrary? { coordinator.library(for: scan.id) }
    private var progress: FixtureCoordinator.Progress? { coordinator.running[scan.id] }
    private var hasPhotos: Bool { store.framesURL(for: scan) != nil }
    private var canDetect: Bool { hasPhotos && FixtureDetectionSupport.status == .available }
    /// The scan has a 3D photo and none is being made right now.
    private var canUseSplat: Bool { canDetect && store.splatURL(for: scan) != nil && !splats.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress {
                header(trailing: nil)
                running(progress)
            } else if let library, !library.fixtures.isEmpty {
                header(trailing: AnyView(reviewButton(library)))
                FixtureCountChips(library: library, units: units)
                if library.uncheckedCount > 0 {
                    Text("\(library.uncheckedCount) to check")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .accessibilityLabel("\(library.uncheckedCount) detected fixtures still to check")
                }
            } else {
                header(trailing: nil)
                empty
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: progress)
        .task(id: scan.id) { coordinator.load(scan, store: store) }
    }

    private func header(trailing: AnyView?) -> some View {
        HStack {
            Text("Fixtures")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }

    private func reviewButton(_ library: FixtureLibrary) -> some View {
        Button(action: onReview) {
            Text(library.uncheckedCount > 0 ? "Review" : "Edit")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(library.uncheckedCount > 0 ? Theme.tile : Theme.accentText)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(library.uncheckedCount > 0 ? Theme.accent : Theme.featured, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(library.uncheckedCount > 0 ? "Review fixtures" : "Edit fixtures")
        .accessibilityHint("Opens the plan and list to confirm, move, change or delete fixtures")
    }

    private func running(_ progress: FixtureCoordinator.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)).tint(Theme.accent)
                Text(progress.label)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().tint(Theme.accent)
                Text("Getting ready…").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var empty: some View {
        Text(library?.detectedAt != nil
             ? "No vents, fans or heaters found."
             : "Vents, bathroom fans and baseboard heaters.")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
        HStack(spacing: 10) {
            if canDetect {
                Button { coordinator.detect(scan, store: store) } label: {
                    Label(library?.detectedAt != nil ? "Scan photos again" : "Find fixtures",
                          systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(FixtureButtonStyle(prominent: library?.detectedAt == nil))
            }
            Button(action: onReview) { Label("Add by hand", systemImage: "plus") }
                .buttonStyle(FixtureButtonStyle(prominent: false))
        }
        if canUseSplat {
            Button { coordinator.detect(scan, store: store, useSplat: true, splatIsBusy: { splats.isBusy }) } label: {
                Label("Check with 3D photo", systemImage: "cube.transparent")
            }
            .buttonStyle(FixtureButtonStyle(prominent: false))
        }
    }
}

/// Chips with symbol, colour and count per kind (kinds with none are left out). Heaters add their total length.
struct FixtureCountChips: View {
    let library: FixtureLibrary
    let units: AppSettings.Units

    var body: some View {
        let f = RoomSummaryFormatter(units: units)
        FlowLayout(spacing: 8) {
            ForEach(Fixture.Kind.allCases, id: \.self) { kind in
                let n = library.count(of: kind)
                if n > 0 {
                    let extra = kind == .baseboardHeater && library.heaterLength > 0 ? f.length(library.heaterLength) : nil
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(kind.color())
                            .accessibilityHidden(true)
                        Text("\(n)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        Text(kind.shortTitle + (n == 1 ? "" : "s"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        if let extra {
                            Text("· \(extra)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(kind.color().opacity(0.14), in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(n) \(n == 1 ? kind.title : kind.pluralTitle)"
                                        + (extra.map { ", about \($0) in total" } ?? ""))
                }
            }
        }
    }
}
