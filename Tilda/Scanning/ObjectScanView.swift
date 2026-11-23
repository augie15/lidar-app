import SwiftUI

/// Object scan entry point. Switches between the photoreal Object Capture flow and the LiDAR quick box scan.
/// Changing the mode tears the current flow down (camera session included) before the other one starts.
struct ObjectScanView: View {
    @AppStorage(AppSettings.Key.objectMode) private var storedMode = AppSettings.ObjectMode.photoreal.rawValue
    /// The flow currently on screen. nil for a beat while one session shuts down and the next begins.
    @State private var activeMode: AppSettings.ObjectMode?
    @State private var switchTask: Task<Void, Never>?

    private var selection: Binding<AppSettings.ObjectMode> {
        Binding(get: { AppSettings.ObjectMode(rawValue: storedMode) ?? .photoreal },
                set: { storedMode = $0.rawValue })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch activeMode {
            case .photoreal: PhotorealObjectScanView(mode: selection)
            case .lidar: LidarObjectScanView(mode: selection)
            case nil: EmptyView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if activeMode == nil { activeMode = selection.wrappedValue } }
        .onChange(of: storedMode) { _, _ in
            let target = selection.wrappedValue
            guard target != activeMode else { return }
            switchTask?.cancel()
            activeMode = nil   // removes the old flow; its onDisappear cancels the session
            switchTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { activeMode = target }
            }
        }
        .onDisappear { switchTask?.cancel() }
    }
}
