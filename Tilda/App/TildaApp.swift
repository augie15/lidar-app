import CoreSpotlight
import SwiftUI

@main
struct TildaApp: App {
    @State private var store = ScanStore()
    @State private var router = NavigationRouter.shared
    @State private var analysis = AnalysisCoordinator()
    @State private var fixtures = FixtureCoordinator()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TildaSelfCheck") {
            let failures = FixturePlacement.selfCheck()
            NSLog("%@", failures.isEmpty ? "FixturePlacement self-check: all passed" : "FixturePlacement self-check FAILED: \(failures)")
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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = UUID(uuidString: id) {
                        router.pendingScanID = uuid
                    }
                }
        }
    }
}
