import SwiftUI
import ARKit

/// Full-screen LiDAR capture. Pick a mode (Mesh, Point cloud, Surfaces), then scan. Done saves into the library:
/// a colored USDZ mesh, a class-colored USDZ plus `surfaces.json`, or a colored `model.ply` point cloud.
struct MeshScanView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.meshMode) private var modeRaw = AppSettings.MeshMode.mesh.rawValue
    /// Set once Start is tapped; the picker disappears and the mode is locked for this scan.
    @State private var active: AppSettings.MeshMode?
    @State private var showUnsupported = false

    private let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private var mode: AppSettings.MeshMode { AppSettings.MeshMode(rawValue: modeRaw) ?? .mesh }

    var body: some View {
        Group {
            if let active {
                MeshScanSession(mode: active)
            } else {
                setup
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { if !supported { showUnsupported = true } }
        .alert("Scan failed", isPresented: $showUnsupported) {
            Button("OK") { dismiss() }
        } message: {
            Text("Mesh scanning needs an iPhone with a LiDAR scanner.")
        }
    }

    // MARK: Before scanning

    private var setup: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(ScanPalette.teal)
                    .frame(width: 72, height: 72)
                    .background(Theme.tile, in: Circle())
                    .accessibilityHidden(true)
                Text(mode.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(mode.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if mode == .pointCloud {
                    Text("Points beyond \(AppSettings.maxRange.formatted()) m are ignored. Change this in Settings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            }
            .animation(.easeOut(duration: 0.2), value: mode)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                ScanTopBar(title: "Mesh scan") { dismiss() }
                MeshModePicker(selection: $modeRaw)
            }
        }
        .overlay(alignment: .bottom) {
            Button { active = mode } label: {
                Text("Start scan")
                    .font(.headline)
                    .foregroundStyle(ScanPalette.tealText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(ScanPalette.teal, in: Capsule())
                    .opacity(supported ? 1 : 0.5)
            }
            .disabled(!supported)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }
}

extension AppSettings.MeshMode {
    var symbol: String {
        switch self {
        case .mesh: "triangle"
        case .pointCloud: "circle.grid.3x3"
        case .classified: "square.3.layers.3d"
        }
    }
}

/// Compact segmented pill (Mesh | Point cloud | Surfaces), styled like the Object scan picker.
struct MeshModePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSettings.MeshMode.allCases) { option in
                let selected = option.rawValue == selection
                Button { selection = option.rawValue } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? ScanPalette.tealText : .white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(selected ? ScanPalette.teal : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.black.opacity(0.5), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
        .animation(.easeOut(duration: 0.2), value: selection)
    }
}

// MARK: - Scanning

private struct MeshScanSession: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller: MeshCaptureController
    @State private var isProcessing = false
    @State private var errorMessage: String?

    init(mode: AppSettings.MeshMode) {
        _controller = StateObject(wrappedValue: MeshCaptureController(mode: mode))
    }

    private var hint: String {
        let base = "Move slowly to fill gaps"
        switch controller.mode {
        case .pointCloud:
            if controller.pointCapReached {
                return "Point limit reached (\(PointCloudCapture.maxPoints.formatted(.number.notation(.compactName)))). Tap Done to save."
            }
            return controller.pointCount == 0 ? base : "\(base) · \(controller.pointCount.formatted(.number.notation(.compactName))) points"
        case .mesh, .classified:
            return controller.faceCount == 0
                ? base
                : "\(base) · \(controller.vertexCount.formatted()) vertices · \(controller.faceCount.formatted()) faces"
        }
    }

    var body: some View {
        ZStack {
            if controller.mode == .mesh {
                MeshARViewRepresentable(controller: controller).ignoresSafeArea()
            } else {
                SceneARViewRepresentable(controller: controller).ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                ScanTopBar(title: "Mesh scan") { close() }
                if controller.mode == .classified {
                    HStack { SurfaceLegend(); Spacer() }.padding(.horizontal, 16)
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let coach = controller.coach, !isProcessing { ScanCoachPill(model: coach) }
                ScanBottomBar(hint: hint, isProcessing: isProcessing) { finish() }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.pause()
            controller.discardRecording()
        }
        .alert("Scan failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func close() {
        controller.pause()
        controller.discardRecording()
        dismiss()
    }

    private func finish() {
        guard !isProcessing else { return }
        isProcessing = true
        let mode = controller.mode
        let keepPhotos = AppSettings.capturePhotos
        let wantColor = AppSettings.colorMesh

        // Snapshots touch ARKit objects: take them here, then do the heavy work off the main thread.
        let work: @Sendable () throws -> (model: URL, extras: [URL])
        switch mode {
        case .mesh:
            let chunks = controller.captureSnapshot()
            let recorder = controller.takeRecorder()
            work = { try Self.buildMesh(chunks: chunks, recorder: recorder, wantColor: wantColor, keepPhotos: keepPhotos) }
        case .classified:
            let surfaces = controller.captureSurfaces()
            let recorder = controller.takeRecorder()
            work = { try Self.buildSurfaces(surfaces, recorder: recorder, keepPhotos: keepPhotos) }
        case .pointCloud:
            let points = controller.capturePoints()
            let recorder = controller.takeRecorder()
            work = { try Self.buildPoints(points, recorder: recorder, keepPhotos: keepPhotos) }
        }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: work).value
                _ = try store.importModel(at: result.model, kind: .mesh, mode: mode.rawValue, attachments: result.extras)
                dismiss()
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Builders (off the main thread)

    /// Finishes the photo recording. Returns the `frames/` folder to keep, or nil (and deletes it) when photos are off.
    nonisolated private static func finishPhotos(_ recorder: FrameRecorder?, keep: Bool) -> URL? {
        guard let dir = recorder?.finish() else { return nil }
        if keep { return dir }
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        return nil
    }

    nonisolated private static func buildMesh(chunks: [WorldMeshChunk], recorder: FrameRecorder?,
                                              wantColor: Bool, keepPhotos: Bool) throws -> (model: URL, extras: [URL]) {
        let framesDir = recorder?.finish()
        func discardFrames() {
            if let dir = framesDir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        }
        var colors: [Data]?
        if wantColor, let dir = framesDir, let manifest = FrameRecorder.load(from: dir) {
            let keyframes = manifest.frames.map { f in
                ColorKeyframe(imageURL: dir.appendingPathComponent(f.file_path), cameraToWorld: f.transform,
                              fx: f.fl_x, fy: f.fl_y, cx: f.cx, cy: f.cy, width: f.w, height: f.h)
            }
            if !keyframes.isEmpty {
                colors = MeshColorizer.colorize(positions: chunks.map(\.positions),
                                                normals: chunks.map(\.normals), keyframes: keyframes)
            }
        }
        let model: URL
        do { model = try MeshExporter.export(chunks: chunks, colors: colors) }
        catch { discardFrames(); throw error }
        if keepPhotos, let framesDir { return (model, [framesDir]) }
        discardFrames()
        return (model, [])
    }

    nonisolated private static func buildSurfaces(_ surfaces: SurfaceSnapshot, recorder: FrameRecorder?,
                                                  keepPhotos: Bool) throws -> (model: URL, extras: [URL]) {
        let framesDir = finishPhotos(recorder, keep: keepPhotos)
        do {
            let model = try MeshExporter.export(chunks: surfaces.chunks, colors: surfaces.colors)
            let json = try MeshExporter.writeSurfaces(surfaces)
            return (model, [json] + (framesDir.map { [$0] } ?? []))
        } catch {
            if let dir = framesDir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            throw error
        }
    }

    nonisolated private static func buildPoints(_ cloud: VoxelCloud?, recorder: FrameRecorder?,
                                                keepPhotos: Bool) throws -> (model: URL, extras: [URL]) {
        let framesDir = finishPhotos(recorder, keep: keepPhotos)
        do {
            guard let cloud else { throw MeshExportError.noPoints }
            let model = try MeshExporter.exportPointCloud(cloud)
            return (model, framesDir.map { [$0] } ?? [])
        } catch {
            if let dir = framesDir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            throw error
        }
    }
}
