import Foundation
import Observation

/// Shared contract for saving and listing scans. Scan views call `importModel`.
@MainActor
@Observable
final class ScanStore {
    private(set) var scans: [Scan] = []

    let rootURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { reload() }

    func folderURL(for scan: Scan) -> URL {
        rootURL.appendingPathComponent(scan.id.uuidString, isDirectory: true)
    }

    func modelURL(for scan: Scan) -> URL {
        folderURL(for: scan).appendingPathComponent(scan.modelFileName)
    }

    /// Keyframes saved with the scan (`frames/images/*.jpg` + `frames/transforms.json`), if any.
    func framesURL(for scan: Scan) -> URL? {
        let url = folderURL(for: scan).appendingPathComponent("frames", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("transforms.json").path) ? url : nil
    }

    /// 2D floor plan saved with Room scans (see FloorPlan), if any.
    func floorPlanURL(for scan: Scan) -> URL? {
        let url = folderURL(for: scan).appendingPathComponent("floorplan.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Measured room facts saved with Room scans (see RoomFacts), if any.
    func roomFactsURL(for scan: Scan) -> URL? {
        let url = folderURL(for: scan).appendingPathComponent(RoomFacts.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Moves a finished model file (usually a .usdz in a temp folder) into the library.
    @discardableResult
    /// `attachments` are extra files or folders (e.g. FrameRecorder's `frames/`, a `floorplan.json`) moved into the
    /// scan folder under their own names.
    func importModel(at sourceURL: URL, kind: ScanKind, name: String? = nil, mode: String? = nil,
                     attachments: [URL] = []) throws -> Scan {
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "usdz" : sourceURL.pathExtension
        let scan = Scan(id: id,
                        name: name ?? Self.defaultName(for: kind),
                        kind: kind,
                        createdAt: .now,
                        modelFileName: "model.\(ext)",
                        mode: mode)
        let folder = folderURL(for: scan)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sourceURL, to: modelURL(for: scan))
        for attachment in attachments {
            try? FileManager.default.moveItem(at: attachment,
                                              to: folder.appendingPathComponent(attachment.lastPathComponent))
        }
        try write(scan)
        scans.insert(scan, at: 0)
        return scan
    }

    func rename(_ scan: Scan, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = scans.firstIndex(where: { $0.id == scan.id }) else { return }
        scans[i].name = trimmed
        try? write(scans[i])
    }

    func delete(_ scan: Scan) {
        try? FileManager.default.removeItem(at: folderURL(for: scan))
        scans.removeAll { $0.id == scan.id }
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scans = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("scan.json")) else { return nil }
            return try? decoder.decode(Scan.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func write(_ scan: Scan) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(scan).write(to: folderURL(for: scan).appendingPathComponent("scan.json"))
    }

    static func defaultName(for kind: ScanKind) -> String {
        "\(kind.title) \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }
}
