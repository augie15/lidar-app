import ARKit
import RealityKit
import SwiftUI

/// LiDAR quick mode: tap a surface to place a box around the object, fit it, scan, and keep only the mesh inside.
struct LidarObjectScanView: View {
    @Binding var mode: AppSettings.ObjectMode
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var controller = LidarObjectController()
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if supported {
                LidarARViewRepresentable(controller: controller).ignoresSafeArea()
            } else {
                Text("Object scanning needs an iPhone with LiDAR.")
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
            ObjectScanTopBar(mode: controller.phase == .scanning || isProcessing ? nil : $mode,
                             showTorch: supported) { close() }
            bottomChrome
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Scan failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { isProcessing = false }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 12) {
            Spacer()
            switch controller.phase {
            case .placing:
                if supported { hint("Tap the surface your object sits on") }
            case .adjusting:
                hint("Fit the box around the object. Tap elsewhere to move it.")
                sliders
                Button { controller.startScanning() } label: {
                    Text("Scan")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ScanPalette.tealText)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(ScanPalette.teal, in: Capsule())
                }
            case .scanning:
                ScanBottomBar(hint: "Walk slowly around the object", isProcessing: isProcessing) { finish() }
                    .padding(.horizontal, -24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, controller.phase == .scanning ? 0 : 24)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
    }

    private var sliders: some View {
        VStack(spacing: 4) {
            sliderRow("Size", value: Binding(get: { Double(controller.size) }, set: { controller.size = Float($0) }),
                      range: Double(LidarObjectController.sizeRange.lowerBound)...Double(LidarObjectController.sizeRange.upperBound))
            sliderRow("Height", value: Binding(get: { Double(controller.height) }, set: { controller.height = Float($0) }),
                      range: Double(LidarObjectController.heightRange.lowerBound)...Double(LidarObjectController.heightRange.upperBound))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
                .tint(ScanPalette.teal)
                .accessibilityLabel("Box \(title.lowercased())")
            Text("\(Int((value.wrappedValue * 100).rounded())) cm")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 58, alignment: .trailing)
        }
    }

    // MARK: Flow

    private func close() {
        controller.stop()
        controller.discardRecording()
        dismiss()
    }

    private func finish() {
        guard !isProcessing, let box = controller.cropBox else { return }
        isProcessing = true
        let snaps = controller.captureSnapshot(box: box)
        let recorder = controller.takeRecorder()
        let wantColor = AppSettings.colorMesh
        Task {
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    try Self.build(snaps: snaps, box: box, recorder: recorder, wantColor: wantColor)
                }.value
                try store.importModel(at: model, kind: .object, mode: AppSettings.ObjectMode.lidar.rawValue)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Off the main thread: crop to the box, paint colors from the recorded frames, write the USDZ.
    nonisolated private static func build(snaps: [ClassifiedChunk], box: CropBox, recorder: FrameRecorder?,
                                          wantColor: Bool) throws -> URL {
        let framesDir = recorder?.finish()
        defer { if let dir = framesDir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) } }

        let chunks = LidarMeshCropper.crop(snaps, box: box)
        guard !chunks.isEmpty else { throw LidarObjectError.nothingInBox }

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
        return try MeshExporter.export(chunks: chunks, colors: colors)
    }
}

enum LidarObjectError: LocalizedError {
    case nothingInBox
    var errorDescription: String? {
        "No surfaces were found inside the box. Resize it around the object and scan again, moving closer."
    }
}

// MARK: - Controller

@MainActor
@Observable
final class LidarObjectController: NSObject, ARSessionDelegate {
    enum Phase { case placing, adjusting, scanning }

    static let sizeRange: ClosedRange<Float> = 0.05...1.2
    static let heightRange: ClosedRange<Float> = 0.02...1.0

    private(set) var phase: Phase = .placing
    /// Footprint side length in metres.
    var size: Float = 0.3 { didSet { size = size.clamped(to: Self.sizeRange); updateBox() } }
    /// Height in metres.
    var height: Float = 0.25 { didSet { height = height.clamped(to: Self.heightRange); updateBox() } }

    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var boxAnchor: AnchorEntity?
    @ObservationIgnored private var edges: [ModelEntity] = []
    @ObservationIgnored private var base = SIMD3<Float>.zero
    @ObservationIgnored private var recorder: FrameRecorder?
    @ObservationIgnored private var recorderTaken = false
    @ObservationIgnored private var stopped = false

    /// The box in world space, once placed.
    var cropBox: CropBox? {
        guard boxAnchor != nil else { return nil }
        let half = size / 2
        return CropBox(min: SIMD3(base.x - half, base.y, base.z - half),
                       max: SIMD3(base.x + half, base.y + height, base.z + half),
                       bottom: base.y)
    }

    func attach(_ view: ARView) {
        arView = view
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        view.debugOptions.insert(.showSceneUnderstanding)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { semantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { semantics.insert(.smoothedSceneDepth) }
        config.frameSemantics = semantics
        view.session.run(config)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        arView?.session.pause()
        arView?.session.delegate = nil
    }

    func startScanning() {
        guard phase == .adjusting else { return }
        phase = .scanning
        if AppSettings.colorMesh { recorder = FrameRecorder(density: .dense) }
    }

    /// Copies the mesh near the box. Call once, when the user taps Done.
    func captureSnapshot(box: CropBox) -> [ClassifiedChunk] {
        let anchors = arView?.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        stop()
        return LidarMeshCropper.snapshot(anchors, near: box)
    }

    func takeRecorder() -> FrameRecorder? {
        recorderTaken = true
        return recorder
    }

    func discardRecording() {
        guard !recorderTaken else { return }
        recorderTaken = true
        recorder?.cancel()
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in self.recorder?.consider(frame) }
    }

    // MARK: Box

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard phase != .scanning, let view = arView else { return }
        let point = gesture.location(in: view)
        guard let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else { return }
        let t = hit.worldTransform.columns.3
        base = SIMD3(t.x, t.y, t.z)
        if boxAnchor == nil {
            let anchor = AnchorEntity(world: base)
            view.scene.addAnchor(anchor)
            boxAnchor = anchor
            let mesh = MeshResource.generateBox(size: 1)
            var material = UnlitMaterial(color: UIColor(ScanPalette.teal))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.75))
            edges = (0..<12).map { _ in ModelEntity(mesh: mesh, materials: [material]) }
            edges.forEach { anchor.addChild($0) }
            phase = .adjusting
        } else {
            boxAnchor?.position = base
        }
        updateBox()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard phase == .adjusting, gesture.state == .changed else { return }
        size *= Float(gesture.scale)
        gesture.scale = 1
    }

    /// Lays out the 12 wireframe edges (thin boxes) for the current size and height.
    private func updateBox() {
        guard let boxAnchor, edges.count == 12 else { return }
        boxAnchor.position = base
        let s = size, h = height, t: Float = 0.004
        var i = 0
        for y in [Float(0), h] {
            for z in [-s / 2, s / 2] {
                place(edges[i], center: [0, y, z], scale: [s + t, t, t]); i += 1
            }
        }
        for x in [-s / 2, s / 2] {
            for z in [-s / 2, s / 2] {
                place(edges[i], center: [x, h / 2, z], scale: [t, h, t]); i += 1
            }
        }
        for y in [Float(0), h] {
            for x in [-s / 2, s / 2] {
                place(edges[i], center: [x, y, 0], scale: [t, t, s + t]); i += 1
            }
        }
    }

    private func place(_ edge: ModelEntity, center: SIMD3<Float>, scale: SIMD3<Float>) {
        edge.position = center
        edge.scale = scale
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

struct LidarARViewRepresentable: UIViewRepresentable {
    let controller: LidarObjectController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
