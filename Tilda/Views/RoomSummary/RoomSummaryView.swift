import SwiftUI

/// Property-measurement summary for a Room scan: totals, mini plan and a card per room.
/// Present as a sheet or push; it brings its own scroll view and loads `roomfacts.json` itself.
struct RoomSummaryView: View {
    let scan: Scan
    @Environment(ScanStore.self) private var store

    private enum Load {
        case loading
        case missing
        case ready(RoomFacts, FloorPlan?)
    }
    @State private var load = Load.loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                RoomSummaryEmptyState()
            case let .ready(facts, plan):
                RoomSummaryScreen(name: scan.name, date: scan.createdAt, facts: facts, plan: plan)
            }
        }
        .background(Theme.background)
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scan.id) { await reload() }
    }

    private func reload() async {
        let factsURL = store.roomFactsURL(for: scan)
        let planURL = store.floorPlanURL(for: scan)
        let result = await Task.detached { () -> (RoomFacts, FloorPlan?)? in
            guard let factsURL, let facts = RoomFacts.load(from: factsURL), !facts.rooms.isEmpty else { return nil }
            return (facts, planURL.flatMap { FloorPlan.load(from: $0) })
        }.value
        if let result { load = .ready(result.0, result.1) } else { load = .missing }
    }
}

struct RoomSummaryEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "ruler")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("No summary for this scan")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Summaries with square footage, room sizes and paint and flooring estimates are available for room scans made with this version of Tilda. Scan the room again to get one.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scrolling page. Takes data directly so previews and tests can feed it a sample.
struct RoomSummaryScreen: View {
    let name: String
    let date: Date
    let facts: RoomFacts
    let plan: FloorPlan?

    var body: some View {
        ScrollView {
            RoomSummaryBody(name: name, date: date, facts: facts, plan: plan)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }
}

struct RoomSummaryBody: View {
    let name: String
    let date: Date
    let facts: RoomFacts
    let plan: FloorPlan?

    @AppStorage(AppSettings.Key.units) private var unitsRaw = AppSettings.Units.imperial.rawValue
    @State private var shareItems: ShareItems?
    @State private var copied = false
    @State private var exportFailed = false

    private var units: AppSettings.Units { AppSettings.Units(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            SummaryHero(facts: facts, units: units)
            if let plan, !plan.walls.isEmpty { SummaryPlan(plan: plan) }
            ForEach(Array(facts.rooms.enumerated()), id: \.offset) { _, room in
                SummaryRoomCard(room: room, units: units)
            }
            Text("Dimensions are approximate and assume rectangular rooms. Paint assumes 10 m² per litre, two coats. Flooring adds 10% for waste.")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 4)
            actions
        }
        .sheet(item: $shareItems) { ShareSheet(urls: $0.urls) }
        .alert("Couldn't create the PDF", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Picker("Units", selection: $unitsRaw) {
                Text("ft").tag(AppSettings.Units.imperial.rawValue)
                Text("m").tag(AppSettings.Units.metric.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 112)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                if let url = RoomSummaryExporter.makePDF(name: name, date: date, facts: facts, plan: plan, units: units) {
                    shareItems = ShareItems(urls: [url])
                } else {
                    exportFailed = true
                }
            } label: {
                Label("Share summary", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .foregroundStyle(Theme.tile)
            }
            Button {
                RoomSummaryExporter.copy(RoomSummaryText.make(name: name, facts: facts, units: units))
                withAnimation(.easeOut(duration: 0.2)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Label(copied ? "Copied" : "Copy as text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

#Preview("Summary") {
    NavigationStack {
        RoomSummaryScreen(name: "Ground floor", date: .now, facts: RoomSummarySample.facts, plan: RoomSummarySample.plan)
            .background(Theme.background)
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    RoomSummaryEmptyState().background(Theme.background).preferredColorScheme(.dark)
}
