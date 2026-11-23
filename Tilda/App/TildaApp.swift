import CoreSpotlight
import SwiftUI

@main
struct TildaApp: App {
    @State private var store = ScanStore()
    @State private var router = NavigationRouter.shared
    @State private var analysis = AnalysisCoordinator()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(router)
                .environment(analysis)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = UUID(uuidString: id) {
                        router.pendingScanID = uuid
                    }
                }
        }
    }
}
