import Foundation
import Observation

/// Carries "open this" requests from App Intents, Siri, Shortcuts and Spotlight to HomeView.
/// Intents run in the app process, so they reach the same instance TildaApp injects.
@MainActor
@Observable
final class NavigationRouter {
    static let shared = NavigationRouter()

    /// A scan cover to present.
    var pendingKind: ScanKind?
    /// A specific saved scan to open.
    var pendingScanID: UUID?
    /// Open whichever scan is newest.
    var pendingLatest = false
}
