import SwiftUI

/// "Fixtures" card on the room summary: vents, bathroom fans and baseboard heaters found in the scan photos or tagged by
/// hand, with the controls to run the photo check again. Detection runs on this iPhone with Apple Intelligence.
struct FixturesCard: View {
    let scan: Scan
    let units: AppSettings.Units

    @Environment(ScanStore.self) private var store
    @Environment(FixtureCoordinator.self) private var coordinator
    @Environment(\.summaryPalette) private var p

    private var library: FixtureLibrary? { coordinator.library(for: scan.id) }
    private var progress: FixtureCoordinator.Progress? { coordinator.running[scan.id] }
    private var hasPhotos: Bool { store.framesURL(for: scan) != nil }
    private var support: FixtureDetectionSupport.Status { FixtureDetectionSupport.status }
    private var found: Bool { !(library?.fixtures.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fixtures")
                .font(.title3.weight(.semibold))
                .foregroundStyle(p.primary)
                .accessibilityAddTraits(.isHeader)

            if let progress {
                running(progress)
            } else {
                if let library, found {
                    FixtureCountList(library: library, units: units, palette: p)
                } else {
                    emptyState
                }
                note
                action
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: progress)
        .task(id: scan.id) { coordinator.load(scan, store: store) }
    }

    // MARK: States

    private func running(_ progress: FixtureCoordinator.Progress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(p.accent)
                Text("Checking photo \(min(progress.done + 1, progress.total)) of \(progress.total)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(p.secondary)
            } else {
                ProgressView().tint(p.accent)
                Text("Getting ready…").font(.subheadline).foregroundStyle(p.secondary)
            }
            Text("Looking for vents, bathroom fans and baseboard heaters. You can leave this screen.")
                .font(.footnote)
                .foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop") { coordinator.cancel(scan.id) }
                .buttonStyle(FixtureButtonStyle(prominent: false))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var emptyState: some View {
        if !hasPhotos {
            message("No photos were saved with this scan, so there is nothing to check.",
                    detail: "Rescan the room with photos on to find fixtures.")
        } else if coordinator.lastRunFailed.contains(scan.id) {
            message("Couldn't read the photos this time.", detail: "Try again in a moment.")
        } else if library?.detectedAt != nil {
            message("No vents, fans or heaters found.",
                    detail: "Open the fixture editor on the scan page to add any that were missed.")
        } else if case let .unavailable(reason) = support {
            message("Not checked yet.", detail: reason)
        } else {
            message("Not checked yet.", detail: "Tilda can look through the scan photos for vents, bathroom fans and baseboard heaters.")
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(p.primary)
            Text(detail).font(.footnote).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var note: some View {
        if let library, found {
            let unchecked = library.uncheckedCount
            Text(unchecked > 0
                 ? "\(unchecked) found in your scan photos on this iPhone \(unchecked == 1 ? "is" : "are") still to check. Review, move or remove fixtures from the scan page."
                 : library.fixtures.contains { $0.source == .detected }
                    ? "Found in your scan photos on this iPhone and checked by you. Edit them from the scan page."
                    : "Added by hand. Edit them from the scan page.")
                .font(.caption)
                .foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var action: some View {
        if hasPhotos {
            let again = library?.detectedAt != nil
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    coordinator.detect(scan, store: store)
                } label: {
                    Label(again ? "Scan photos again" : "Find fixtures", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(FixtureButtonStyle(prominent: !again && support == .available))
                .disabled(support != .available)
                if case let .unavailable(reason) = support, found || library?.detectedAt != nil {
                    Text(reason).font(.caption).foregroundStyle(p.muted)
                }
            }
        }
    }
}

struct FixtureButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(prominent ? Theme.tile : Theme.accentText)
            .background(prominent ? Theme.accent : Theme.featured,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// Fixtures block for the PDF: the same counts, without controls.
struct SummaryFixturesBlock: View {
    let library: FixtureLibrary
    let units: AppSettings.Units
    @Environment(\.summaryPalette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fixtures").font(.title3.weight(.semibold)).foregroundStyle(p.primary)
            FixtureCountList(library: library, units: units, palette: p)
            Text("Found in the scan photos by on-device image analysis, plus any added by hand. Confirm on site.")
                .font(.caption)
                .foregroundStyle(p.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}
