import AppIntents
import Foundation

/// A saved scan, exposed to Shortcuts and Spotlight.
struct ScanEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scan")
    static let defaultQuery = ScanEntityQuery()

    var id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Type") var kind: String
    var createdAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(kind) · \(createdAt.formatted(date: .abbreviated, time: .omitted))",
                              image: .init(systemName: ScanKind(rawValue: kind.lowercased())?.symbol ?? "cube"))
    }

    init(_ scan: Scan) {
        id = scan.id
        createdAt = scan.createdAt
        name = scan.name
        kind = scan.kind.title
    }
}

struct ScanEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ScanEntity] {
        await scans().filter { identifiers.contains($0.id) }.map(ScanEntity.init)
    }

    func suggestedEntities() async throws -> [ScanEntity] {
        await scans().prefix(10).map(ScanEntity.init)
    }

    func entities(matching string: String) async throws -> [ScanEntity] {
        let all = await scans()
        let needle = string.lowercased()
        return all.filter { scan in
            scan.name.lowercased().contains(needle) || scan.kind.title.lowercased().contains(needle)
                || AnalysisSearch.matches(scan: scan, needle: needle)
        }.map(ScanEntity.init)
    }

    @MainActor
    private func scans() -> [Scan] {
        let store = ScanStore()
        return store.scans
    }
}

/// Search over a scan's saved insights without needing the running coordinator.
enum AnalysisSearch {
    static func matches(scan: Scan, needle: String) -> Bool {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans/\(scan.id.uuidString)", isDirectory: true)
        return ScanInsights.load(from: folder)?.searchText.contains(needle) ?? false
    }
}
