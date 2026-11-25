import Foundation

/// User-adjustable settings. Read with @AppStorage(AppSettings.Key.x) in views, or AppSettings.x elsewhere.
enum AppSettings {
    enum Key {
        static let capturePhotos = "capturePhotos"
        static let photoDensity = "photoDensity"
        static let scanningTips = "scanningTips"
        static let roomDetail = "roomDetail"
        static let colorMesh = "colorMesh"
        static let flashOnStart = "flashOnStart"
        static let units = "units"
        static let wallThickness = "wallThickness"
        // Object
        static let objectMode = "objectMode"
        static let objectOverCapture = "objectOverCapture"
        static let objectMasking = "objectMasking"
        static let objectHighSensitivity = "objectHighSensitivity"
        static let objectSequential = "objectSequential"
        static let objectKeepImages = "objectKeepImages"
        // Mesh / LiDAR
        static let meshMode = "meshMode"
        static let depthConfidence = "depthConfidence"
        static let maxRange = "maxRange"
        static let pointSpacing = "pointSpacing"
        static let removePeople = "removePeople"
        static let highResVideo = "highResVideo"
        static let smoothDepth = "smoothDepth"
        // Insights
        static let scanFocus = "scanFocus"
        static let focusPromptAnswered = "focusPromptAnswered"
    }

    // MARK: Units

    enum Units: String, CaseIterable, Identifiable {
        case imperial, metric
        var id: String { rawValue }
        var title: String { self == .imperial ? "Feet (sq ft)" : "Metres (m²)" }
    }

    /// Display units for measurements. Defaults to imperial (square footage).
    static var units: Units { Units(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial }

    /// Assumed wall thickness for "estimated gross area", in metres. Choices: 0.10 (4 in), 0.15 (6 in), 0.20 (8 in).
    static var wallThickness: Float { Float(defaults.object(forKey: Key.wallThickness) as? Double ?? 0.15) }

    // MARK: Object modes and options

    enum ObjectMode: String, CaseIterable, Identifiable {
        /// Object Capture photos, model built on the phone (Apple allows "reduced" detail on iPhone).
        case photoreal
        /// LiDAR mesh inside a box around the object: instant, works on shiny or plain objects.
        case lidar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photoreal: "Photoreal"
            case .lidar: "LiDAR quick"
            }
        }
        var detail: String {
            switch self {
            case .photoreal: "Textured model built on your iPhone"
            case .lidar: "Instant shape from LiDAR, good for shiny or plain objects"
            }
        }
    }

    static var objectMode: ObjectMode { ObjectMode(rawValue: defaults.string(forKey: Key.objectMode) ?? "") ?? .photoreal }
    /// Object Capture over-capture: takes extra shots for a better model.
    static var objectOverCapture: Bool { defaults.object(forKey: Key.objectOverCapture) as? Bool ?? true }
    /// On: model only the object. Off: keep the surface it sits on.
    static var objectMasking: Bool { defaults.object(forKey: Key.objectMasking) as? Bool ?? true }
    /// High feature sensitivity, for objects with little texture.
    static var objectHighSensitivity: Bool { defaults.bool(forKey: Key.objectHighSensitivity) }
    /// Treat photos as a sequence: faster processing.
    static var objectSequential: Bool { defaults.object(forKey: Key.objectSequential) as? Bool ?? true }
    /// Keep the Object Capture photos with the scan (`images/` in the scan folder) so they can be exported and
    /// rebuilt at full/raw detail on a Mac (iPhone reconstruction is limited to Apple's "reduced" detail).
    static var objectKeepImages: Bool { defaults.bool(forKey: Key.objectKeepImages) }

    // MARK: Mesh / LiDAR modes and options

    enum MeshMode: String, CaseIterable, Identifiable {
        /// Triangle mesh from ARKit scene reconstruction, optionally colored from the camera.
        case mesh
        /// Colored point cloud from the LiDAR depth map.
        case pointCloud
        /// Mesh colored by surface type (wall, floor, ceiling, table, seat, door, window).
        case classified
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mesh: "Mesh"
            case .pointCloud: "Point cloud"
            case .classified: "Surfaces"
            }
        }
        var detail: String {
            switch self {
            case .mesh: "Solid surfaces, colored from the camera"
            case .pointCloud: "Millions of colored LiDAR points"
            case .classified: "Walls, floor, furniture and more in separate colors"
            }
        }
    }

    enum DepthConfidence: Int, CaseIterable, Identifiable {
        case low = 0, medium = 1, high = 2
        var id: Int { rawValue }
        var title: String { ["Low", "Medium", "High"][rawValue] }
        var detail: String { ["Most points, more noise", "Balanced", "Cleanest, fewer points"][rawValue] }
    }

    static var meshMode: MeshMode { MeshMode(rawValue: defaults.string(forKey: Key.meshMode) ?? "") ?? .mesh }
    /// Minimum LiDAR confidence a depth sample needs to be kept (point cloud).
    static var depthConfidence: DepthConfidence { DepthConfidence(rawValue: defaults.object(forKey: Key.depthConfidence) as? Int ?? 1) ?? .medium }
    /// Ignore depth beyond this many metres (LiDAR is reliable to about 5 m). Choices: 1.5, 3, 5.
    static var maxRange: Double { defaults.object(forKey: Key.maxRange) as? Double ?? 3.0 }
    /// Point cloud voxel spacing in millimetres. Choices: 5, 10, 20.
    static var pointSpacing: Int { defaults.object(forKey: Key.pointSpacing) as? Int ?? 10 }
    /// Mask out people walking through the scan.
    static var removePeople: Bool { defaults.bool(forKey: Key.removePeople) }
    /// Run the camera at 4K for sharper colors and photos (uses more power).
    static var highResVideo: Bool { defaults.bool(forKey: Key.highResVideo) }
    /// Use ARKit's temporally smoothed depth instead of raw per-frame depth.
    static var smoothDepth: Bool { defaults.object(forKey: Key.smoothDepth) as? Bool ?? true }

    /// How densely keyframes are kept while scanning.
    enum PhotoDensity: String, CaseIterable, Identifiable {
        case light, standard, dense
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: "Light"
            case .standard: "Standard"
            case .dense: "Dense"
            }
        }
        var detail: String {
            switch self {
            case .light: "Fewer photos, smaller scans"
            case .standard: "Good for tours and color"
            case .dense: "Best for 3D photos and photoreal 3D, uses more storage"
            }
        }
        /// (metres moved, degrees turned, max photos) before a new keyframe is kept.
        var thresholds: (translation: Float, rotationDegrees: Float, maxFrames: Int) {
            switch self {
            case .light: (0.6, 25, 120)
            case .standard: (0.3, 15, 250)
            case .dense: (0.15, 8, 900)   // big rooms for 3D photos need the headroom
            }
        }
    }

    /// RoomPlan export style.
    enum RoomDetail: String, CaseIterable, Identifiable {
        case simple, detailed
        var id: String { rawValue }
        var title: String { self == .simple ? "Simple" : "Detailed" }
        var detail: String { self == .simple ? "Clean boxes for walls and furniture" : "Real furniture shapes, larger files" }
    }

    private static var defaults: UserDefaults { .standard }

    /// What the owner scans for. Shapes Insights summaries. Defaults to General.
    static var focus: ScanFocus { ScanFocus(rawValue: defaults.string(forKey: Key.scanFocus) ?? "") ?? .general }
    /// True once the "What do you scan for?" sheet has been answered or skipped.
    static var focusPromptAnswered: Bool { defaults.bool(forKey: Key.focusPromptAnswered) }

    /// Save camera photos with each Room and Mesh scan (needed for photo tours, color and photoreal export).
    static var capturePhotos: Bool { defaults.object(forKey: Key.capturePhotos) as? Bool ?? true }
    /// Live reminders to change height and angle while scanning (default on).
    static var scanningTips: Bool { defaults.object(forKey: Key.scanningTips) as? Bool ?? true }
    static var photoDensity: PhotoDensity { PhotoDensity(rawValue: defaults.string(forKey: Key.photoDensity) ?? "") ?? .standard }
    static var roomDetail: RoomDetail { RoomDetail(rawValue: defaults.string(forKey: Key.roomDetail) ?? "") ?? .simple }
    /// Paint the mesh with colors from the camera.
    static var colorMesh: Bool { defaults.object(forKey: Key.colorMesh) as? Bool ?? true }
    /// Turn the flashlight on automatically when a scan opens.
    static var flashOnStart: Bool { defaults.bool(forKey: Key.flashOnStart) }
}
