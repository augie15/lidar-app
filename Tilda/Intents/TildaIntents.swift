import AppIntents
import Foundation

struct StartRoomScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a room scan"
    static let description = IntentDescription("Opens Tilda ready to scan a room.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 18 to 25: the older way to say "open the app".
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NavigationRouter.shared.pendingKind = .room
        return .result()
    }
}

struct StartObjectScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Start an object scan"
    static let description = IntentDescription("Opens Tilda ready to scan an object.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 18 to 25: the older way to say "open the app".
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NavigationRouter.shared.pendingKind = .object
        return .result()
    }
}

struct StartMeshScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a mesh scan"
    static let description = IntentDescription("Opens Tilda ready to capture a LiDAR mesh.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 18 to 25: the older way to say "open the app".
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NavigationRouter.shared.pendingKind = .mesh
        return .result()
    }
}

struct OpenLatestScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Open my latest scan"
    static let description = IntentDescription("Opens your most recent scan in Tilda.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 18 to 25: the older way to say "open the app".
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NavigationRouter.shared.pendingLatest = true
        return .result()
    }
}

struct OpenScanIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a scan"
    static let description = IntentDescription("Opens a scan from your library in Tilda.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 18 to 25: the older way to say "open the app".
    static let openAppWhenRun = true

    @Parameter(title: "Scan") var target: ScanEntity

    @MainActor func perform() async throws -> some IntentResult {
        NavigationRouter.shared.pendingScanID = target.id
        return .result()
    }
}

struct TildaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRoomScanIntent(),
                    phrases: ["Start a room scan in \(.applicationName)", "Scan a room with \(.applicationName)"],
                    shortTitle: "Room scan", systemImageName: "square.split.bottomrightquarter")
        AppShortcut(intent: StartObjectScanIntent(),
                    phrases: ["Start an object scan in \(.applicationName)", "Scan an object with \(.applicationName)"],
                    shortTitle: "Object scan", systemImageName: "cube")
        AppShortcut(intent: StartMeshScanIntent(),
                    phrases: ["Start a mesh scan in \(.applicationName)", "Scan a mesh with \(.applicationName)"],
                    shortTitle: "Mesh scan", systemImageName: "triangle")
        AppShortcut(intent: OpenLatestScanIntent(),
                    phrases: ["Open my latest scan in \(.applicationName)", "Show my last scan in \(.applicationName)"],
                    shortTitle: "Latest scan", systemImageName: "clock")
    }
}
