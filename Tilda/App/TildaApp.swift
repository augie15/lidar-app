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
        if ProcessInfo.processInfo.arguments.contains("-TildaResetFocusPrompt") {
            UserDefaults.standard.removeObject(forKey: AppSettings.Key.focusPromptAnswered)
        }
        if let dir = UserDefaults.standard.string(forKey: "TildaSplatViews") {
            Task { await SplatViewRenderer.writeSampleViews(to: URL(fileURLWithPath: dir, isDirectory: true)) }
        }
        if ProcessInfo.processInfo.arguments.contains("-TildaSelfCheck") {
            let coachFailures = ScanCoach.selfCheck()
            NSLog("%@", coachFailures.isEmpty ? "Scan coach self-check: all passed" : "Scan coach self-check FAILED: \(coachFailures)")
            let failures = FixturePlacement.selfCheck()
            NSLog("%@", failures.isEmpty ? "FixturePlacement self-check: all passed" : "FixturePlacement self-check FAILED: \(failures)")
            let splatFailures = SplatMath.selfCheck()
            NSLog("%@", splatFailures.isEmpty ? "Splat self-check: all passed" : "Splat self-check FAILED: \(splatFailures)")
            let viewFailures = SplatViewPlanner.selfCheck() + FixtureDetectorStorage.selfCheck()
            NSLog("%@", viewFailures.isEmpty ? "Splat view self-check: all passed" : "Splat view self-check FAILED: \(viewFailures)")
            Task {
                let renderFailures = await SplatViewRenderer.renderSelfCheck()
                NSLog("%@", renderFailures.isEmpty ? "Splat view render self-check: all passed" : "Splat view render self-check FAILED: \(renderFailures)")
            }
        }
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "TildaCoachPreview") {
            ScanCoachPreviewScreen(tip: CoachTip(rawValue: name))
        } else {
            HomeView()
        }
        #else
        HomeView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
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
