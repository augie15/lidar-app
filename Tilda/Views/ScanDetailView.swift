import SwiftUI
import QuickLook

struct ScanDetailView: View {
    let scanID: UUID
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(FixtureCoordinator.self) private var fixtureCoordinator

    @State private var exportingFormat: ExportFormat?
    @State private var shareItems: ShareItems?
    @State private var exportError: String?
    @State private var showRename = false
    @State private var showDelete = false
    @State private var draftName = ""
    @State private var arPreviewURL: URL?
    @State private var showTour = false
    @State private var showWalkthrough = false
    @State private var showAsk = false
    @State private var showRoomSummary = false

    private var scan: Scan? { store.scans.first { $0.id == scanID } }

    var body: some View {
        Group {
            if let scan {
                content(for: scan)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .quickLookPreview($arPreviewURL)
        .fullScreenCover(isPresented: $showTour) {
            if let scan { PhotoTourView(scan: scan).environment(store).environment(fixtureCoordinator) }
        }
        .fullScreenCover(isPresented: $showWalkthrough) {
            if let scan {
                WalkthroughView(modelURL: store.modelURL(for: scan), floorPlanURL: store.floorPlanURL(for: scan))
            }
        }
        .sheet(isPresented: $showAsk) {
            if let scan {
                AskScanView(scan: scan, folder: store.folderURL(for: scan), modelURL: store.modelURL(for: scan),
                            insights: analysis.insights[scan.id])
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showRoomSummary) {
            if let scan {
                NavigationStack {
                    RoomSummaryView(scan: scan)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("Done") { showRoomSummary = false } }
                        }
                }
                .environment(store)
                .environment(fixtureCoordinator)
                .tint(Theme.accent)
                .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: scan == nil) { _, gone in if gone { dismiss() } }
    }

    private func content(for scan: Scan) -> some View {
        let url = store.modelURL(for: scan)
        let formats = ExportFormat.available(in: store.folderURL(for: scan))
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ModelPreview(url: url)
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if url.pathExtension.lowercased() == "usdz" {
                            Button { arPreviewURL = url } label: {
                                Label("View in AR", systemImage: "arkit")
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.featured, in: Capsule())
                                    .foregroundStyle(Theme.accentText)
                            }
                            .padding(12)
                        }
                    }
                    .accessibilityLabel("3D preview of \(scan.name)")

                Text(infoLine(for: scan, url: url))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                viewButtons(for: scan)

                InsightsCard(insights: analysis.insights[scan.id], busy: analysis.isBusy(scan.id)) {
                    analysis.reanalyze(scan, store: store)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Export as")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(formats.filter { $0 != .photos && $0 != .macPhotos }) { format in
                            exportButton(format, scan: scan, url: url)
                        }
                    }
                    if formats.contains(.photos) {
                        exportButton(.photos, scan: scan, url: url)
                        Text("For photoreal 3D apps on a computer")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if formats.contains(.macPhotos) {
                        exportButton(.macPhotos, scan: scan, url: url)
                        Text("Rebuild at full detail with Object Capture on a Mac")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { draftName = scan.name; showRename = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Rename scan", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.rename(scan, to: draftName) }
        }
        .confirmationDialog("Delete this scan?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(scan) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scan and its files from your iPhone.")
        }
        .sheet(item: $shareItems) { items in
            ShareSheet(urls: items.urls).presentationDetents([.medium, .large])
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder
    private func viewButtons(for scan: Scan) -> some View {
        let hasTour = store.framesURL(for: scan) != nil
        let canWalk = scan.kind == .room || scan.kind == .mesh
        let showSummary = scan.kind == .room
        let canAsk = ScanIntelligence.isModelAvailable
        if hasTour || canWalk || showSummary || canAsk {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                if showSummary { viewButton("Room summary", symbol: "list.bullet.rectangle") { showRoomSummary = true } }
                if hasTour { viewButton("Photo tour", symbol: "photo.on.rectangle.angled") { showTour = true } }
                if canWalk { viewButton("Walk through", symbol: "figure.walk") { showWalkthrough = true } }
                if canAsk { viewButton("Ask", symbol: "sparkles") { showAsk = true } }
            }
        }
    }

    private func viewButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(Theme.accentText)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.featured, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private func exportButton(_ format: ExportFormat, scan: Scan, url: URL) -> some View {
        let busy = exportingFormat == format
        return Button {
            Task { await export(scan: scan, url: url, format: format) }
        } label: {
            ZStack {
                Text(format.title)
                    .font(.headline)
                    .opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(Theme.accent) }
            }
            .foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(exportingFormat != nil)
        .accessibilityLabel("Export as \(format.title)")
    }

    private func export(scan: Scan, url: URL, format: ExportFormat) async {
        exportingFormat = format
        defer { exportingFormat = nil }
        do {
            let urls = try await ExportService.export(modelURL: url, name: scan.name, as: format)
            shareItems = ShareItems(urls: urls)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func modeTitle(for scan: Scan) -> String? {
        guard let mode = scan.mode else { return nil }
        switch scan.kind {
        case .object: return AppSettings.ObjectMode(rawValue: mode)?.title
        case .mesh: return AppSettings.MeshMode(rawValue: mode)?.title
        case .room: return nil
        }
    }

    private func infoLine(for scan: Scan, url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let date = scan.createdAt.formatted(date: .abbreviated, time: .shortened)
        return [scan.kind.title, modeTitle(for: scan), sizeText, date].compactMap { $0 }.joined(separator: " · ")
    }
}
