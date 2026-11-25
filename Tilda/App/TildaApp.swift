import CoreSpotlight
import SwiftUI

@main
struct TildaApp: App {
    @State private var store = ScanStore()
    @State private var router = NavigationRouter.shared
    @State private var analysis = AnalysisCoordinator()
    @State private var fixtures = FixtureCoordinator()
    @State private var splats = SplatCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TildaSelfCheck") {
            let failures = FixturePlacement.selfCheck()
            NSLog("%@", failures.isEmpty ? "FixturePlacement self-check: all passed" : "FixturePlacement self-check FAILED: \(failures)")
            let splatFailures = SplatMath.selfCheck()
            NSLog("%@", splatFailures.isEmpty ? "Splat self-check: all passed" : "Splat self-check FAILED: \(splatFailures)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(router)
                .environment(analysis)
                .environment(fixtures)
                .environment(splats)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { splats.appMovedToBackground() }
                }
                .onChange(of: store.scans.map(\.id)) { _, _ in splats.sync(store: store) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = UUID(uuidString: id) {
                        router.pendingScanID = uuid
                    }
                }
        }
    }
}
