import SwiftUI
import QuickLook

struct ScanDetailView: View {
    let scanID: UUID
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(FixtureCoordinator.self) private var fixtureCoordinator
    @Environment(SplatCoordinator.self) private var splatCoordinator

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
    @State private var showSplatViewer = false
    /// Bumped when a splat file appears or goes away, since the file system isn't observable.
    @State private var splatRevision = 0
    @State private var showFixtureMarkers = true
    @State private var editor: FixtureEditorRequest?
    /// Set when the editor closes with a fixture selected: the 3D preview pulses it for a moment.
    @State private var focusedFixture: UUID?
    /// Set when the editor asks for the photo tour: the tour opens once the editor has gone.
    @State private var tourFocus: UUID?
    @State private var planWalls: [FloorPlan.Segment] = []

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
        .fullScreenCover(isPresented: $showTour, onDismiss: { tourFocus = nil }) {
            if let scan {
                PhotoTourView(scan: scan, focusFixture: tourFocus).environment(store).environment(fixtureCoordinator)
            }
        }
        .fullScreenCover(isPresented: $showWalkthrough) {
            if let scan {
                WalkthroughView(modelURL: store.modelURL(for: scan), floorPlanURL: store.floorPlanURL(for: scan),
                                fixtures: scan.kind == .room ? fixtureCoordinator.fixtures(for: scan.id) : [])
            }
        }
        .fullScreenCover(isPresented: $showSplatViewer, onDismiss: { splatRevision += 1 }) {
            if let scan, let splatURL = store.splatURL(for: scan) {
                SplatViewerView(scan: scan, splatURL: splatURL)
                    .environment(store)
                    .environment(splatCoordinator)
            } else {
                // No file (the DEBUG card preview, or it was removed meanwhile): never leave a cover with no way out.
                VStack(spacing: 16) {
                    Text("This 3D photo isn't on your iPhone any more.")
                        .font(.headline).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Close") { showSplatViewer = false }
                        .buttonStyle(FixtureButtonStyle(prominent: true))
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .sheet(item: $editor, onDismiss: {
            if tourFocus != nil { showTour = true }
        }) { request in
            if let scan {
                FixtureEditorView(scan: scan, focus: request.focus, onClose: { id in pulse(id) },
                                  onOpenTour: { tourFocus = $0 })
                    .environment(store)
                    .environment(fixtureCoordinator)
            }
        }
        .task(id: scanID) { await loadWalls() }
        #if DEBUG
        .task(id: scanID) {
            guard SplatDebugSample.isRequested, let scan else { return }
            await SplatDebugSample.write(to: store.folderURL(for: scan).appendingPathComponent("splat.ply"))
            splatRevision += 1
        }
        #endif
        // Watched from a child view: reading the phase here would rebuild this whole page on every progress tick.
        .background { SplatFileWatcher(scanID: scanID) { splatRevision += 1 } }
        .sheet(isPresented: $showAsk) {
            if #available(iOS 26.0, *), let scan {
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
        _ = splatRevision
        let url = store.modelURL(for: scan)
        let formats = ExportFormat.available(in: store.folderURL(for: scan))
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ModelPreview(url: url, fixtures: markerFixtures(for: scan), walls: planWalls,
                             showFixtures: showFixtureMarkers, focusedFixture: focusedFixture,
                             onSelectFixture: { id in editor = FixtureEditorRequest(focus: id) })
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if !markerFixtures(for: scan).isEmpty { fixtureToggle }
                    }
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

                if SplatCard.isVisible(scan: scan, store: store) {
                    SplatCard(scan: scan) { showSplatViewer = true }
                        .environment(splatCoordinator)
                }

                if scan.kind == .room {
                    FixturesRow(scan: scan) { editor = FixtureEditorRequest() }
                }

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

    private func markerFixtures(for scan: Scan) -> [Fixture] {
        scan.kind == .room ? fixtureCoordinator.fixtures(for: scan.id) : []
    }

    /// "Fixtures" chip on the preview: shows or hides the 3D markers.
    private var fixtureToggle: some View {
        Button { showFixtureMarkers.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: showFixtureMarkers ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text("Fixtures").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(showFixtureMarkers ? Theme.tile : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(showFixtureMarkers ? Theme.accent : Color.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .padding(6)
        .accessibilityLabel("Fixtures")
        .accessibilityValue(showFixtureMarkers ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides vent, fan and heater markers in the 3D preview")
    }

    private func pulse(_ id: UUID?) {
        guard let id else { return }
        showFixtureMarkers = true
        focusedFixture = id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if focusedFixture == id { focusedFixture = nil }
        }
    }

    private func loadWalls() async {
        guard let scan, scan.kind == .room, let url = store.floorPlanURL(for: scan) else { return }
        planWalls = await Task.detached { FloorPlan.load(from: url)?.walls ?? [] }.value
        fixtureCoordinator.load(scan, store: store)
    }

    @ViewBuilder
    private func viewButtons(for scan: Scan) -> some View {
        let hasTour = store.framesURL(for: scan) != nil
        let canWalk = scan.kind == .room || scan.kind == .mesh
        let showSummary = scan.kind == .room
        let canAsk = ScanIntelligence.isModelAvailable
        let hasSplat = store.splatURL(for: scan) != nil || SplatCardPreview.hasSplat == true
        if hasTour || canWalk || showSummary || canAsk || hasSplat {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                if showSummary { viewButton("Room summary", symbol: "list.bullet.rectangle") { showRoomSummary = true } }
                if hasTour { viewButton("Photo tour", symbol: "photo.on.rectangle.angled") { showTour = true } }
                if canWalk { viewButton("Walk through", symbol: "figure.walk") { showWalkthrough = true } }
                if hasSplat { viewButton("3D photo", symbol: "cube.transparent") { showSplatViewer = true } }
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
