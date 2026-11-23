import ARKit
import RealityKit
import SceneKit
import SwiftUI

/// Owns one ARKit scan run for a chosen `MeshMode`: session configuration, live statistics and the final snapshot.
@MainActor
final class MeshCaptureController: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var pointCount = 0
    @Published var pointCapReached = false

    nonisolated let mode: AppSettings.MeshMode
    /// Keyframe recorder, present when photos (or mesh vertex colors) are wanted. Thread-safe, fed from the delegate.
    nonisolated let recorder: FrameRecorder?
    /// Live point cloud builder (point cloud mode only).
    nonisolated(unsafe) private(set) var cloud: PointCloudCapture?
    /// Root of the live point nodes, added to the scene by the SceneKit view.
    let cloudRoot = SCNNode()
    private let tailNode = SCNNode()

    private var recorderTaken = false
    private weak var session: ARSession?
    private var anchors: [UUID: ARMeshAnchor] = [:]
    private var paused = false

    init(mode: AppSettings.MeshMode) {
        self.mode = mode
        switch mode {
        case .mesh: recorder = (AppSettings.capturePhotos || AppSettings.colorMesh) ? FrameRecorder() : nil
        case .classified, .pointCloud: recorder = AppSettings.capturePhotos ? FrameRecorder() : nil
        }
        super.init()
        cloudRoot.addChildNode(tailNode)
    }

    // MARK: Session

    /// Shared configuration for all modes: depth, people masking and 4K video follow the settings when supported.
    static func configuration(for mode: AppSettings.MeshMode) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        switch mode {
        case .mesh:
            config.sceneReconstruction = .mesh
        case .classified:
            config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification : .mesh
        case .pointCloud:
            config.sceneReconstruction = []
        }
        config.environmentTexturing = .none
        if AppSettings.highResVideo, let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format
        }
        var semantics: ARConfiguration.FrameSemantics = []
        let depth: ARConfiguration.FrameSemantics = AppSettings.smoothDepth ? .smoothedSceneDepth : .sceneDepth
        if ARWorldTrackingConfiguration.supportsFrameSemantics(depth) { semantics.insert(depth) }
        if AppSettings.removePeople, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            semantics.insert(.personSegmentationWithDepth)
        }
        config.frameSemantics = semantics
        return config
    }

    private func run(_ session: ARSession) {
        self.session = session
        session.delegate = self
        if mode == .pointCloud {
            let options = PointCloudCapture.Options(
                minConfidence: UInt8(AppSettings.depthConfidence.rawValue),
                maxRange: Float(AppSettings.maxRange),
                cellSize: Float(AppSettings.pointSpacing) / 1000,
                removePeople: AppSettings.removePeople,
                smooth: AppSettings.smoothDepth)
            cloud = PointCloudCapture(options: options) { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }
        }
        session.run(Self.configuration(for: mode))
    }

    /// RealityKit view (Mesh mode): ARKit's scene understanding overlay.
    func attach(_ view: ARView) {
        view.automaticallyConfigureSession = false
        view.debugOptions.insert(.showSceneUnderstanding)
        run(view.session)
    }

    /// SceneKit view (Point cloud and Surfaces modes).
    func attach(_ view: ARSCNView) {
        view.delegate = self
        view.scene.rootNode.addChildNode(cloudRoot)
        run(view.session)
    }

    func pause() {
        guard !paused else { return }
        paused = true
        session?.pause()
    }

    private func apply(_ update: PointCloudCapture.Update) {
        guard !paused else { return }
        for g in update.frozen { cloudRoot.addChildNode(SCNNode(geometry: g)) }
        tailNode.geometry = update.tail
        pointCount = update.count
        pointCapReached = update.capped
    }

    // MARK: Snapshots

    private func currentMeshAnchors() -> [ARMeshAnchor] {
        let current = session?.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        return current.isEmpty ? Array(anchors.values) : current
    }

    /// Pauses the session and copies all mesh geometry into world space.
    func captureSnapshot() -> [WorldMeshChunk] {
        let all = currentMeshAnchors()
        pause()
        return MeshExporter.snapshot(all)
    }

    /// Pauses the session and builds the class-colored mesh plus per-class areas.
    func captureSurfaces() -> SurfaceSnapshot {
        let all = currentMeshAnchors()
        pause()
        return SurfaceMesh.snapshot(all)
    }

    /// Pauses the session and returns the deduped point cloud.
    func capturePoints() -> VoxelCloud? {
        pause()
        return cloud?.finish()
    }

    /// Hands the recorder to the export step; the caller owns finishing and cleaning it up.
    func takeRecorder() -> FrameRecorder? {
        recorderTaken = true
        return recorder
    }

    /// Throws away recorded photos if the scan was abandoned.
    func discardRecording() {
        guard !recorderTaken else { return }
        recorderTaken = true
        recorder?.cancel()
    }

    // MARK: ARSessionDelegate

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        recorder?.consider(frame)
        cloud?.consider(frame)
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { update(anchors) }
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { update(anchors) }
    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            for id in ids { self.anchors[id] = nil }
            self.recount()
        }
    }

    private nonisolated func update(_ new: [ARAnchor]) {
        let meshes = new.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor in
            for a in meshes { self.anchors[a.identifier] = a }
            self.recount()
        }
    }

    private func recount() {
        vertexCount = anchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        faceCount = anchors.values.reduce(0) { $0 + $1.geometry.faces.count }
    }

    // MARK: ARSCNViewDelegate (Surfaces mode draws the mesh itself)

    nonisolated func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard mode == .classified, let mesh = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode()
        node.geometry = SurfaceMesh.liveGeometry(for: mesh)
        return node
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard mode == .classified, let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = SurfaceMesh.liveGeometry(for: mesh)
    }
}

/// RealityKit AR view for Mesh mode.
struct MeshARViewRepresentable: UIViewRepresentable {
    let controller: MeshCaptureController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// SceneKit AR view for Point cloud and Surfaces modes.
struct SceneARViewRepresentable: UIViewRepresentable {
    let controller: MeshCaptureController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.autoenablesDefaultLighting = controller.mode == .classified
        view.antialiasingMode = controller.mode == .classified ? .multisampling2X : .none
        view.rendersCameraGrain = false
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
