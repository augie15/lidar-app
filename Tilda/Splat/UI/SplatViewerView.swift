import SwiftUI

/// Full-screen viewer for a finished 3D photo (Gaussian splat). One finger orbits, pinch zooms, two fingers pan,
/// double-tap resets.
struct SplatViewerView: View {
    let scan: Scan
    let splatURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store
    @Environment(SplatCoordinator.self) private var coordinator

    @State private var model = SplatViewerModel()
    @State private var commands = SplatViewerCommands()
    @State private var showHint = true
    @State private var shareItems: ShareItems?
    @State private var confirmDelete = false
    @State private var flipped: Bool

    init(scan: Scan, splatURL: URL) {
        self.scan = scan
        self.splatURL = splatURL
        _flipped = State(initialValue: UserDefaults.standard.bool(forKey: Self.flipKey(scan.id)))
    }

    private static func flipKey(_ id: UUID) -> String { "splatFlipped.\(id.uuidString)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SplatMetalView(url: splatURL, flipped: flipped, startsInside: scan.kind != .object, model: model, commands: commands)
                .ignoresSafeArea()
                .opacity(model.state == .loading ? 0 : 1)
            switch model.state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Opening 3D photo…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(spacing: 8) {
                    Text("This 3D photo can't be opened.")
                        .font(.headline).foregroundStyle(.white)
                    Text(message).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)
                .padding(32)
                .accessibilityElement(children: .combine)
            case .ready:
                EmptyView()
            }
        }
        .overlay(alignment: .top) { topBar }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: 0.6)) { showHint = false }
        }
        .sheet(item: $shareItems, onDismiss: Self.removeShareCopies) { items in
            ShareSheet(urls: items.urls).presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete this 3D photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete 3D photo", role: .destructive) {
                coordinator.deleteSplat(scan, store: store)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the 3D photo from your iPhone. The scan stays, and you can make a new one.")
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            chromeButton("xmark", label: "Close") { dismiss() }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(scan.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(.black.opacity(0.45), in: Capsule())
                if showHint, model.state != .loading {
                    Text("Drag to orbit · pinch to zoom · two fingers to pan")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button { shareItems = ShareItems(urls: [shareableCopy()]) } label: {
                    Label("Share file", systemImage: "square.and.arrow.up")
                }
                Button { commands.reset() } label: { Label("Reset view", systemImage: "arrow.counterclockwise") }
                Button { toggleFlip() } label: { Label("Turn upside down", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete 3D photo", systemImage: "trash")
                }
            } label: {
                chromeIcon("ellipsis")
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func chromeButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chromeIcon(symbol) }
            .accessibilityLabel(label)
    }

    private func chromeIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.45), in: Circle())
            .frame(width: 44, height: 44)
    }

    private func toggleFlip() {
        flipped.toggle()
        UserDefaults.standard.set(flipped, forKey: Self.flipKey(scan.id))
    }

    /// One folder for the share copy: only one share sheet is open at a time, and it is emptied when the sheet closes.
    private static var shareDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("splat-share") }

    private static func removeShareCopies() { try? FileManager.default.removeItem(at: shareDirectory) }

    /// A copy named after the scan, so the share sheet and Files show a readable name instead of "splat.ply".
    private func shareableCopy() -> URL {
        let safe = scan.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
        Self.removeShareCopies()     // also clears a copy left behind if the app quit with the sheet open
        let dir = Self.shareDirectory
        let dest = dir.appendingPathComponent("\(safe.isEmpty ? "3D photo" : safe).ply")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: splatURL, to: dest)
            return dest
        } catch {
            return splatURL
        }
    }
}
