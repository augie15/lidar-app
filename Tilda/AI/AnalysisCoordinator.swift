import Foundation
import Observation

/// Runs scan analysis in the background, one scan at a time, keeps an in-memory copy of every scan's insights for
/// search, and keeps the Spotlight index in step with `store.scans` (new, renamed, deleted).
@MainActor
@Observable
final class AnalysisCoordinator {
    private(set) var insights: [UUID: ScanInsights] = [:]
    private(set) var busy: Set<UUID> = []     // running or queued

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var attempted: Set<UUID> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var indexed: [UUID: String] = [:]
    @ObservationIgnored private weak var store: ScanStore?

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    /// Call whenever `store.scans` changes. `autoAnalyze` is the `aiAutoAnalyze` setting.
    func sync(store: ScanStore, autoAnalyze: Bool) {
        self.store = store
        let ids = Set(store.scans.map(\.id))
        for gone in insights.keys where !ids.contains(gone) { insights[gone] = nil }
        let removed = indexed.keys.filter { !ids.contains($0) }
        SpotlightIndexer.remove(ids: Array(removed))
        removed.forEach { indexed[$0] = nil }

        for scan in store.scans {
            if insights[scan.id] == nil {
                insights[scan.id] = ScanIntelligence.load(folder: store.folderURL(for: scan))
            }
            reindexIfNeeded(scan, store: store)
            if autoAnalyze, needsAnalysis(scan), !attempted.contains(scan.id), !queue.contains(scan.id) {
                queue.append(scan.id)
                busy.insert(scan.id)
            }
        }
        startWorker()
    }

    /// Detail screen "Re-analyze".
    func reanalyze(_ scan: Scan, store: ScanStore) {
        self.store = store
        guard !busy.contains(scan.id) else { return }
        attempted.remove(scan.id)
        queue.append(scan.id)
        busy.insert(scan.id)
        startWorker()
    }

    // MARK: Internals

    private func needsAnalysis(_ scan: Scan) -> Bool {
        guard let existing = insights[scan.id] else { return true }
        return !existing.usedLanguageModel && ScanIntelligence.isModelAvailable
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let id = self.queue.first {
                self.queue.removeFirst()
                if let scan = self.store?.scans.first(where: { $0.id == id }) { await self.run(scan) }
                self.busy.remove(id)
            }
            self?.worker = nil
        }
    }

    private func run(_ scan: Scan) async {
        guard let store else { return }
        attempted.insert(scan.id)
        let folder = store.folderURL(for: scan)
        guard let result = await ScanIntelligence.analyze(scan: scan, folder: folder, modelURL: store.modelURL(for: scan))
        else { return }
        insights[scan.id] = result
        // Rename only while the scan still carries its default "<Kind> <date>" name.
        if !result.suggestedName.isEmpty, Self.hasDefaultName(scan),
           let current = store.scans.first(where: { $0.id == scan.id }), Self.hasDefaultName(current) {
            store.rename(current, to: result.suggestedName)
        }
        if let latest = store.scans.first(where: { $0.id == scan.id }) { reindexIfNeeded(latest, store: store) }
    }

    private func reindexIfNeeded(_ scan: Scan, store: ScanStore) {
        let signature = [scan.name, insights[scan.id]?.summary ?? "", insights[scan.id]?.tags.joined(separator: ",") ?? ""]
            .joined(separator: "|")
        guard indexed[scan.id] != signature else { return }
        indexed[scan.id] = signature
        SpotlightIndexer.index(scan: scan, insights: insights[scan.id], folder: store.folderURL(for: scan))
    }

    /// Matches `ScanStore.defaultName(for:)`: the kind title followed by a date and time.
    static func hasDefaultName(_ scan: Scan) -> Bool {
        let prefix = scan.kind.title + " "
        guard scan.name.hasPrefix(prefix) else { return false }
        return scan.name.dropFirst(prefix.count).contains(where: \.isNumber)
    }

    // MARK: Search

    func matches(_ scan: Scan, query: String) -> Bool {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = (scan.name + " " + scan.kind.title).lowercased() + " " + (insights[scan.id]?.searchText ?? "")
        return terms.allSatisfy { haystack.contains($0) }
    }
}
