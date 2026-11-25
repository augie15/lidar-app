import SwiftUI

/// "3D photo" card on a scan's page: make a Gaussian splat from the scan's photos, follow its progress, and open it.
/// Shown only when the scan has the photos training needs, or already has a finished splat.
struct SplatCard: View {
    let scan: Scan
    let onView: () -> Void

    @Environment(ScanStore.self) private var store
    @Environment(SplatCoordinator.self) private var coordinator
    @AppStorage("splatQuality") private var qualityRaw = SplatQuality.quick.rawValue
    @State private var remaking = false
    @State private var lastAnnounced = -1
    /// The quick photo check (nil until it has run).
    @State private var readiness: SplatReadiness.Report?

    private var quality: SplatQuality { SplatQuality(rawValue: qualityRaw) ?? .quick }

    // The values below read through `SplatCardPreview` so DEBUG builds can show every state in the Simulator.
    private var phase: SplatPhase { SplatCardPreview.phase ?? coordinator.phase(for: scan.id) }
    private var canTrain: Bool { SplatCardPreview.active || SplatSupport.canTrain }
    private var hasSplat: Bool { SplatCardPreview.hasSplat ?? (store.splatURL(for: scan) != nil) }
    /// Another scan holds the trainer. True in any phase where this scan is not the one working (idle, paused, failed,
    /// finished), so its Resume / Try again / Make again can't silently pause the other run.
    private var busyElsewhere: Bool { SplatCardPreview.busyElsewhere ?? (coordinator.isBusy && !isWorkingHere) }

    private var isWorkingHere: Bool {
        switch phase {
        case .preparing, .training, .saving, .cooling: true
        case .idle, .paused, .tooHot, .failed, .finished: false
        }
    }

    /// Whether the page should show the card at all.
    static func isVisible(scan: Scan, store: ScanStore) -> Bool {
        if SplatCardPreview.active { return true }
        let hasInputs = SplatSupport.hasInputs(scanFolder: store.folderURL(for: scan))
        let hasSplat = store.splatURL(for: scan) != nil
        return hasSplat || (hasInputs && SplatSupport.canTrain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3D photo")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: phase)
        .animation(.easeOut(duration: 0.2), value: remaking)
        .onChange(of: phase) { _, new in announce(new) }
        .task(id: scan.id) {
            let folder = store.folderURL(for: scan)
            readiness = await Task.detached(priority: .utility) { SplatReadiness.assess(scanFolder: folder) }.value
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .preparing(let step):
            working(title: step.isEmpty ? "Getting ready…" : step, progress: nil, detail: nil)
            cancelButton
        case .training(let progress, let count, let secondsLeft):
            working(title: "Making your 3D photo · \(percent(progress))", progress: progress,
                    detail: trainingDetail(count: count, secondsLeft: secondsLeft))
            keepOpenNote
            cancelButton
        case .saving:
            working(title: "Saving…", progress: nil, detail: nil)
        case .paused(let progress):
            Text("Paused at \(percent(progress))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            // Pauses come from leaving Tilda, starting another scan's 3D photo, or the phone running low on memory.
            Text("It stopped before it finished. Resume to carry on from there.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            if busyElsewhere { busy }
            HStack(spacing: 10) {
                if !busyElsewhere {
                    Button { start() } label: { Text("Resume") }
                        .buttonStyle(FixtureButtonStyle(prominent: true))
                }
                Button { coordinator.cancel(scan.id) } label: { Text("Cancel") }
                    .buttonStyle(FixtureButtonStyle(prominent: false))
            }
        case .cooling(let progress):
            working(title: "Cooling down · \(percent(progress))", progress: progress,
                    detail: "Your iPhone got hot, so training is taking a break. It carries on by itself once it cools.")
            keepOpenNote
            cancelButton
        case .tooHot(let progress):
            Text("Stopped at \(percent(progress)) to protect your iPhone")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("It got too hot. Let it cool, take it off the charger or out of its case, then resume from here.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            if busyElsewhere { busy }
            HStack(spacing: 10) {
                if !busyElsewhere {
                    Button { start() } label: { Text("Resume") }
                        .buttonStyle(FixtureButtonStyle(prominent: true))
                }
                Button { coordinator.cancel(scan.id) } label: { Text("Cancel") }
                    .buttonStyle(FixtureButtonStyle(prominent: false))
            }
        case .failed(let message):
            Text(message.isEmpty ? "Something went wrong making the 3D photo." : message)
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            if busyElsewhere {
                busy
            } else {
                Button { start() } label: { Text("Try again") }
                    .buttonStyle(FixtureButtonStyle(prominent: true))
            }
        case .finished:
            if remaking { chooser } else { finished }
        case .idle:
            if hasSplat && !remaking { finished } else if busyElsewhere { busy } else if canTrain { chooser }
        }
    }

    // MARK: States

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn this scan's photos into a 3D scene you can look around, a Gaussian splat.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Quality", selection: $qualityRaw) {
                    ForEach(SplatQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(quality.detail).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            if let readiness { readinessView(readiness) }
            Button { start() } label: { Text("Make 3D photo") }
                .buttonStyle(FixtureButtonStyle(prominent: true))
            Text("Runs on your iPhone and can take a while. Keep Tilda open; the screen stays on.")
                .font(.footnote).foregroundStyle(Theme.textMuted)
            if remaking {
                Button("Keep the current one") { remaking = false }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
            }
        }
    }

    /// What the photo check expects, with the reasons and what to do next time.
    private func readinessView(_ report: SplatReadiness.Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: report.grade == .good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(report.grade == .good ? Theme.accent : Theme.textSecondary)
                    .accessibilityHidden(true)
                Text("Expected result: \(report.grade.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if report.grade == .good {
                Text("\(report.photoCount) photos from enough angles for a sharp 3D photo.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(report.issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                    Text("\(issue.problem) \(issue.fix)")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("You can still make it; it will be less sharp.")
                    .font(.footnote).foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var busy: some View {
        Text("Another scan is making its 3D photo. Carry on with this one when it finishes.")
            .font(.footnote).foregroundStyle(Theme.textSecondary)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onView) {
                Label("View 3D photo", systemImage: "cube.transparent")
            }
            .buttonStyle(FixtureButtonStyle(prominent: true))
            if canTrain && !busyElsewhere {
                Button("Make again") { remaking = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
                    .accessibilityHint("Replaces this 3D photo with a new one")
            }
        }
    }

    private func working(title: String, progress: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(Theme.accent)
            } else {
                ProgressView().tint(Theme.accent)
            }
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress == nil ? title : "Making your 3D photo")
        .accessibilityValue(progress.map { "\(percent($0)) done" + ($0 < 1 ? (detail.map { ", \($0)" } ?? "") : "") } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var keepOpenNote: some View {
        Text("Keep Tilda open until it finishes.")
            .font(.footnote).foregroundStyle(Theme.textMuted)
    }

    private var cancelButton: some View {
        Button { coordinator.cancel(scan.id) } label: { Text("Cancel") }
            .buttonStyle(FixtureButtonStyle(prominent: false))
    }

    // MARK: Helpers

    private func start() {
        remaking = false
        coordinator.start(scan, store: store, quality: quality)
    }

    private func percent(_ p: Double) -> String { "\(Int((min(max(p, 0), 1) * 100).rounded()))%" }

    private func trainingDetail(count: Int, secondsLeft: Double?) -> String? {
        var parts: [String] = []
        if count > 0 { parts.append("\(count.formatted()) splats") }
        if let s = secondsLeft, s.isFinite, s >= 0 {
            parts.append(s < 60 ? "less than a minute left" : "about \(Int((s / 60).rounded())) min left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// VoiceOver hears the quarter marks and the end, not every percent.
    private func announce(_ new: SplatPhase) {
        var text: String?
        switch new {
        case .training(let p, _, _):
            let q = Int(p * 4) * 25
            if q > lastAnnounced && q > 0 { lastAnnounced = q; text = "3D photo \(q) percent" }
        case .finished: text = "3D photo ready"; lastAnnounced = -1
        case .failed: text = "3D photo failed"; lastAnnounced = -1
        case .paused: text = "3D photo paused"
        case .cooling: text = "3D photo paused to let your iPhone cool down"
        case .tooHot: text = "3D photo stopped because your iPhone is too hot"
        case .idle: lastAnnounced = -1
        default: break
        }
        if let text { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}

/// Calls `onChange` when a scan's splat file may have appeared or gone (a run finished, or a finished splat was
/// deleted). Its own view, so the per-tick progress updates it reads rebuild only this empty view, not the scan page.
struct SplatFileWatcher: View {
    let scanID: UUID
    let onChange: () -> Void
    @Environment(SplatCoordinator.self) private var coordinator

    var body: some View {
        Color.clear
            .onChange(of: coordinator.phase(for: scanID) == .finished) { _, _ in onChange() }
    }
}

/// DEBUG only: `-TildaSplatCardState idle|busy|preparing|training|saving|paused|cooling|toohot|failed|finished` fakes a state so the
/// card can be seen in the Simulator, which can't train. Always inactive in Release.
enum SplatCardPreview {
    static var raw: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "TildaSplatCardState")
        #else
        nil
        #endif
    }
    static var active: Bool { raw != nil }
    static var busyElsewhere: Bool? { raw == nil ? nil : raw == "busy" }
    static var hasSplat: Bool? { raw == nil ? nil : raw == "finished" || raw == "sample" }
    static var phase: SplatPhase? {
        switch raw {
        case "preparing": .preparing(step: "Checking photo sharpness")
        case "training": .training(progress: 0.42, splatCount: 184_000, secondsLeft: 150)
        case "saving": .saving
        case "paused": .paused(progress: 0.42)
        case "cooling": .cooling(progress: 0.58)
        case "toohot": .tooHot(progress: 0.58)
        case "failed": .failed(message: "Ran out of memory. Close other apps and try again.")
        case "finished": .finished
        case nil: nil
        default: .idle
        }
    }
}
