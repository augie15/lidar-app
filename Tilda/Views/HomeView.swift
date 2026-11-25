import SwiftUI

struct HomeView: View {
    @Environment(ScanStore.self) private var store
    @Environment(NavigationRouter.self) private var router
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(FixtureCoordinator.self) private var fixtures
    @AppStorage("aiAutoAnalyze") private var autoAnalyze = true
    @State private var query = ""
    @State private var activeKind: ScanKind?
    @State private var unsupportedKind: ScanKind?
    @State private var path: [Scan] = []
    @State private var showSettings = false
    @State private var showFocusPrompt = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                tiles
                    .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
                scansSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Scan.self) { ScanDetailView(scanID: $0.id) }
        }
        .tint(Theme.accent)
        // Re-runs on any change to the scan list (new, renamed, deleted): background analysis and Spotlight upkeep.
        .task(id: store.scans) { sync() }
        .onChange(of: autoAnalyze) { sync() }
        .onChange(of: router.pendingKind, initial: true) { handleRoute() }
        .onChange(of: router.pendingScanID, initial: true) { handleRoute() }
        .onChange(of: router.pendingLatest, initial: true) { handleRoute() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showFocusPrompt, onDismiss: {
            // Any way out (Continue, Skip, swipe down) counts as answered; the default stays General.
            UserDefaults.standard.set(true, forKey: AppSettings.Key.focusPromptAnswered)
        }) { FocusPromptView() }
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            maybeAskFocus()
        }
        .onChange(of: activeKind) { maybeAskFocus() }
        .onChange(of: path) { maybeAskFocus() }
        .onChange(of: showSettings) { maybeAskFocus() }
        .fullScreenCover(item: $activeKind, onDismiss: { store.reload() }) { kind in
            switch kind {
            case .room: RoomScanView()
            case .object: ObjectScanView()
            case .mesh: MeshScanView()
            }
        }
        .alert("Not available on this iPhone",
               isPresented: Binding(get: { unsupportedKind != nil },
                                    set: { if !$0 { unsupportedKind = nil } }),
               presenting: unsupportedKind) { _ in
            Button("OK", role: .cancel) {}
        } message: { kind in
            Text(DeviceSupport.unsupportedMessage(for: kind))
        }
    }

    /// Shows "What do you scan for?" once, from the home screen only: never over a scan, a detail screen or Settings.
    private func maybeAskFocus() {
        // The focus only shapes Apple Intelligence summaries, which need iOS 26.
        guard #available(iOS 26.0, *), !AppSettings.focusPromptAnswered, !showFocusPrompt, activeKind == nil, path.isEmpty, !showSettings,
              router.pendingKind == nil, router.pendingScanID == nil, !router.pendingLatest else { return }
        showFocusPrompt = true
    }

    private func sync() {
        analysis.sync(store: store, autoAnalyze: autoAnalyze)
        fixtures.sync(store: store, autoDetect: autoAnalyze)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TildaMark().frame(width: 52, height: 52)
            Text("Tilda")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Settings")
        }
        .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var tiles: some View {
        VStack(spacing: 12) {
            ModeTile(kind: .room, featured: true) { start(.room) }
            HStack(spacing: 12) {
                ModeTile(kind: .object) { start(.object) }
                ModeTile(kind: .mesh) { start(.mesh) }
            }
        }
        .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var scansSection: some View {
        Text("Your scans")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        if !store.scans.isEmpty { searchField }

        if store.scans.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("Your first scan starts here")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a mode above and point your iPhone at a space or an object.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        } else {
            if filteredScans.isEmpty {
                Text("No scans match \u{201C}\(query)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(filteredScans) { scan in
                // A plain button pushes the detail screen; NavigationLink in a List adds a second chevron.
                Button { path.append(scan) } label: { ScanRow(scan: scan) }
                    .buttonStyle(PressableStyle())
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.delete(scan) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private var filteredScans: [Scan] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? store.scans : store.scans.filter { analysis.matches($0, query: q) }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("Search name, tags, text", text: $query)
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func handleRoute() {
        if let kind = router.pendingKind {
            router.pendingKind = nil
            showSettings = false
            path = []
            start(kind)
        }
        if router.pendingLatest {
            router.pendingLatest = false
            if let latest = store.scans.first { router.pendingScanID = latest.id }
        }
        if let id = router.pendingScanID {
            router.pendingScanID = nil
            if let scan = store.scans.first(where: { $0.id == id }) {
                activeKind = nil
                showSettings = false
                path = [scan]
            }
        }
    }

    private func start(_ kind: ScanKind) {
        if DeviceSupport.isSupported(kind) {
            activeKind = kind
        } else {
            unsupportedKind = kind
        }
    }
}

#Preview {
    HomeView().environment(ScanStore()).environment(NavigationRouter.shared)
        .environment(AnalysisCoordinator()).preferredColorScheme(.dark)
}
