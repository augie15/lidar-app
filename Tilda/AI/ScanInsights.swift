import Foundation

/// On-device analysis of a scan, saved as `insights.json` in the scan folder.
/// Facts are computed deterministically; only `suggestedName` and `summary` come from the language model.
struct ScanInsights: Codable, Sendable, Equatable {
    struct Fact: Codable, Sendable, Hashable {
        var label: String
        var value: String
    }

    var suggestedName: String
    var summary: String
    var tags: [String]
    var facts: [Fact]
    var recognizedText: [String]
    var analyzedAt: Date = .now
    /// False when Apple Intelligence was unavailable and only facts, tags and text were produced.
    var usedLanguageModel: Bool = true

    static let fileName = "insights.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    func write(to folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url(in: folder), options: .atomic)
    }

    static func load(from folder: URL) -> ScanInsights? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanInsights.self, from: data)
    }

    /// Lower-cased text the library search matches against.
    var searchText: String {
        ([suggestedName, summary] + tags + recognizedText).joined(separator: " ").lowercased()
    }
}
