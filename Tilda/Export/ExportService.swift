import Foundation
import ModelIO

enum ExportFormat: String, CaseIterable, Identifiable {
    case usdz, obj, stl, ply
    /// Zip of the scan's keyframes + camera poses (Nerfstudio `transforms.json`) for Gaussian-splat /
    /// photogrammetry tools on a computer.
    case photos
    /// Zip of the Object Capture photos (`images/`) for full/raw detail reconstruction on a Mac.
    case macPhotos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photos: "Photos + poses"
        case .macPhotos: "Photos for Mac"
        default: rawValue.uppercased()
        }
    }

    /// Formats that make sense for a scan folder. Photo exports only when those photos were saved.
    static func available(in scanFolder: URL) -> [ExportFormat] {
        let fm = FileManager.default
        let hasFrames = fm.fileExists(atPath: scanFolder.appendingPathComponent("frames/transforms.json").path)
        let hasImages = fm.fileExists(atPath: scanFolder.appendingPathComponent("images").path)
        // Point clouds (model.ply) have no faces, so USDZ/OBJ/STL conversions would be empty or invalid.
        let isPointCloud = fm.fileExists(atPath: scanFolder.appendingPathComponent("model.ply").path)
        return allCases.filter {
            switch $0 {
            case .photos: hasFrames
            case .macPhotos: hasImages
            case .ply: true
            case .usdz, .obj, .stl: !isPointCloud
            }
        }
    }
}

enum ExportError: LocalizedError {
    case unsupported(String)
    case failed(String, underlying: Error?)
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return "This device cannot export \(ext.uppercased()) files."
        case .failed(let ext, let underlying):
            return "Exporting to \(ext.uppercased()) failed" + (underlying.map { ": \($0.localizedDescription)" } ?? ".")
        case .noOutput(let ext):
            return "The \(ext.uppercased()) export produced no files."
        }
    }
}

/// Converts a stored model into share-ready files. Safe to call from any task.
enum ExportService {
    /// Returns file URLs ready for a share sheet (OBJ may return .obj + .mtl + textures).
    static func export(modelURL: URL, name: String, as format: ExportFormat) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try exportSync(modelURL: modelURL, name: name, format: format)
        }.value
    }

    private static func exportSync(modelURL: URL, name: String, format: ExportFormat) throws -> [URL] {
        let fm = FileManager.default
        let base = sanitize(name)
        let ext = format.rawValue
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("\(base).\(ext)")

        if format == .photos {
            return [try zipPhotos(scanFolder: modelURL.deletingLastPathComponent(), modelURL: modelURL,
                                  base: base, into: dir)]
        }

        if format == .macPhotos {
            let images = modelURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
            return [try zipFolder(images, named: "\(base) photos for Mac", into: dir)]
        }

        // Same format as the stored model (USDZ scans, PLY point clouds): copy the original bytes.
        if format.rawValue == modelURL.pathExtension.lowercased() {
            do { try fm.copyItem(at: modelURL, to: outURL) }
            catch { throw ExportError.failed(ext, underlying: error) }
            return [outURL]
        }

        guard MDLAsset.canExportFileExtension(ext) else { throw ExportError.unsupported(ext) }

        let asset = MDLAsset(url: modelURL)
        if format == .obj { asset.loadTextures() }
        do { try asset.export(to: outURL) }
        catch { throw ExportError.failed(ext, underlying: error) }

        let produced = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard fm.fileExists(atPath: outURL.path) else { throw ExportError.noOutput(ext) }
        // Main file first, then .mtl / textures / anything else written beside it.
        let extras = produced.filter { $0 != outURL && !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return [outURL] + extras
    }

    /// Builds "<name> photos.zip" containing images/, transforms.json and the model (useful as a starting
    /// point cloud). Uses NSFileCoordinator's built-in zipping, so no third-party code.
    private static func zipPhotos(scanFolder: URL, modelURL: URL, base: String, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let frames = scanFolder.appendingPathComponent("frames", isDirectory: true)
        guard fm.fileExists(atPath: frames.appendingPathComponent("transforms.json").path) else {
            throw ExportError.noOutput("photos")
        }
        let staging = dir.appendingPathComponent("\(base) photos", isDirectory: true)
        do {
            try fm.copyItem(at: frames, to: staging)
            // Views rendered from the 3D photo live beside the photos for fixture checks; they are not camera photos.
            for folder in [FixtureDetectorStorage.folder, FixtureDetectorStorage.tempFolder] {
                try? fm.removeItem(at: staging.appendingPathComponent(folder, isDirectory: true))
            }
            try? fm.copyItem(at: modelURL, to: staging.appendingPathComponent("model.\(modelURL.pathExtension)"))
        } catch { throw ExportError.failed("photos", underlying: error) }

        defer { try? fm.removeItem(at: staging) }
        return try zipFolder(staging, named: "\(base) photos", into: dir)
    }

    /// Zips a folder with NSFileCoordinator's built-in `.forUploading` zipping.
    private static func zipFolder(_ folder: URL, named name: String, into dir: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: folder.path) else { throw ExportError.noOutput("zip") }
        let zipURL = dir.appendingPathComponent("\(name).zip")
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { tempZip in
            do { try FileManager.default.copyItem(at: tempZip, to: zipURL) } catch { copyError = error }
        }
        if let error = coordError ?? copyError { throw ExportError.failed("zip", underlying: error) }
        return zipURL
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Model" : String(cleaned.prefix(80))
    }
}
