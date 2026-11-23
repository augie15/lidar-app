import Foundation

/// The three capture modes. Owned by the skeleton; do not rename cases.
enum ScanKind: String, Codable, CaseIterable, Identifiable {
    case room, object, mesh
    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: "Room"
        case .object: "Object"
        case .mesh: "Mesh"
        }
    }
}

/// One saved scan. Stored at Documents/Scans/<id>/scan.json next to its model file.
struct Scan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let kind: ScanKind
    let createdAt: Date
    /// File name of the model inside the scan folder, e.g. "model.usdz".
    var modelFileName: String
    /// Capture mode within the kind, e.g. "photoreal", "lidar", "forMac", "mesh", "pointCloud", "classified".
    /// Optional so scans saved before modes existed still load.
    var mode: String?
}
