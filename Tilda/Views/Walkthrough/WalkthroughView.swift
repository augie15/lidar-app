import SceneKit
import SwiftUI
import simd

/// First-person walk through a scan: drag the right side to look, use the stick at the bottom-left to move.
struct WalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WalkthroughModel
    @State private var showHint = true
    @State private var lookAnchor: CGSize = .zero

    init(modelURL: URL, floorPlanURL: URL?, fixtures: [Fixture] = []) {
        _model = StateObject(wrappedValue: WalkthroughModel(modelURL: modelURL, floorPlanURL: floorPlanURL,
                                                            fixtures: fixtures))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scene = model.scene {
                WalkthroughSceneView(scene: scene, model: model).ignoresSafeArea()
            } else if model.failed {
                Text("This scan can't be opened for a walkthrough.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay { lookSurface }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottomLeading) {
            ThumbStick { model.setMove($0) }
                .padding(.leading, 28)
                .padding(.bottom, 32)
                .accessibilityLabel("Move")
                .accessibilityHint("Adjust to walk forward or back")
                .accessibilityAdjustableAction { direction in
                    model.nudge(forward: direction == .increment ? 0.5 : -0.5)
                }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: 0.6)) { showHint = false }
        }
    }

    /// Right 60% of the screen: dragging here turns the view.
    private var lookSurface: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: geo.size.width * 0.6, height: geo.size.height)
                .position(x: geo.size.width * 0.7, y: geo.size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let d = CGSize(width: value.translation.width - lookAnchor.width,
                                           height: value.translation.height - lookAnchor.height)
                            lookAnchor = value.translation
                            model.look(dx: Float(d.width), dy: Float(d.height))
                        }
                        .onEnded { _ in lookAnchor = .zero }
                )
                .accessibilityHidden(true)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            if showHint {
                Text("Drag to look · stick to move")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.top, 4)
                    .transition(.opacity)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - Thumb stick

private struct ThumbStick: View {
    let onChange: (SIMD2<Float>) -> Void
    private let baseSize: CGFloat = 132
    private let knobSize: CGFloat = 56
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.45))
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            Circle()
                .fill(ScanPalette.teal.opacity(offset == .zero ? 0.75 : 1))
                .frame(width: knobSize, height: knobSize)
                .offset(offset)
        }
        .frame(width: baseSize, height: baseSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let travel = (baseSize - knobSize) / 2
                    var v = CGSize(width: value.translation.width, height: value.translation.height)
                    let len = hypot(v.width, v.height)
                    if len > travel { v = CGSize(width: v.width / len * travel, height: v.height / len * travel) }
                    offset = v
                    // Screen up = forward. Returns (right, forward) in -1...1.
                    onChange(SIMD2(Float(v.width / travel), Float(-v.height / travel)))
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.18)) { offset = .zero }
                    onChange(.zero)
                }
        )
    }
}

// MARK: - Scene view

private struct WalkthroughSceneView: UIViewRepresentable {
    let scene: SCNScene
    let model: WalkthroughModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.isUserInteractionEnabled = false   // touches go to the SwiftUI controls above
        view.scene = scene
        view.pointOfView = model.cameraNode
        view.delegate = model
        view.isPlaying = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

// MARK: - Model

/// Owns the scene, the first-person camera and the walking simulation. Input arrives from the main thread; movement
/// is integrated per frame on SceneKit's render thread, so shared state sits behind a lock.
final class WalkthroughModel: NSObject, ObservableObject, SCNSceneRendererDelegate, @unchecked Sendable {
    @Published private(set) var scene: SCNScene?
    @Published private(set) var failed = false

    let cameraNode = SCNNode()

    private let modelURL: URL
    private let plan: FloorPlan?
    private let fixtures: [Fixture]

    static let eyeHeight: Float = 1.6
    static let walkSpeed: Float = 1.2        // metres per second at full stick
    static let radius: Float = 0.25          // body radius for wall collision
    static let lookSensitivity: Float = 0.005 // radians per point
    static let maxPitch: Float = 1.3         // about 75 degrees

    private let lock = NSLock()
    private var position = SIMD3<Float>.zero
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var move = SIMD2<Float>.zero     // (right, forward)
    private var lastTime: TimeInterval?
    private var walls: [(SIMD2<Float>, SIMD2<Float>)] = []
    private var gaps: [(SIMD2<Float>, SIMD2<Float>)] = []

    init(modelURL: URL, floorPlanURL: URL?, fixtures: [Fixture] = []) {
        self.modelURL = modelURL
        self.fixtures = fixtures
        self.plan = floorPlanURL.flatMap { FloorPlan.load(from: $0) }
        super.init()
        if let plan {
            walls = plan.walls.map { ($0.start, $0.end) }
            gaps = (plan.doors + plan.openings).map { ($0.start, $0.end) }
        }
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 200
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 75
        cameraNode.camera = camera
        cameraNode.name = "walkthrough-camera"
    }

    // MARK: Loading

    private struct Loaded: @unchecked Sendable { let scene: SCNScene }

    @MainActor
    func load() async {
        guard scene == nil else { return }
        let url = modelURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
            return Loaded(scene: scene)
        }.value
        guard let scene = loaded?.scene else { failed = true; return }
        configure(scene)
        self.scene = scene
    }

    private func configure(_ scene: SCNScene) {
        ModelPreview.prepareMaterials(in: scene)
        if !fixtures.isEmpty { FixtureSceneMarkers.install(fixtures, walls: plan?.walls ?? [], in: scene, throughWalls: false) }

        let (minB, maxB) = scene.rootNode.boundingBox
        let bMin = SIMD3<Float>(Float(minB.x), Float(minB.y), Float(minB.z))
        let bMax = SIMD3<Float>(Float(maxB.x), Float(maxB.y), Float(maxB.z))

        // Eye height above the floor, and the footprint to start in.
        let floorY = plan?.floorY ?? bMin.y
        var lo = SIMD2(bMin.x, bMin.z), hi = SIMD2(bMax.x, bMax.z)
        if let plan, !(plan.walls.isEmpty && plan.objects.isEmpty) {
            (lo, hi) = plan.bounds
        }
        let center = (lo + hi) / 2
        let size = hi - lo

        lock.withLock {
            position = SIMD3(center.x, floorY + Self.eyeHeight, center.y)
            // yaw 0 looks down -Z, pi/2 looks down -X. Face the longest direction.
            yaw = size.y >= size.x ? 0 : .pi / 2
            pitch = 0
            lastTime = nil
        }
        applyCamera()

        // Light untextured RoomPlan models so walls and furniture read clearly.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        ambient.light?.color = UIColor(white: 1, alpha: 1)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi * 0.8, 0)
        for node in [ambient, key, fill, cameraNode] { scene.rootNode.addChildNode(node) }
    }

    // MARK: Input

    func look(dx: Float, dy: Float) {
        lock.withLock {
            yaw -= dx * Self.lookSensitivity
            pitch = min(max(pitch - dy * Self.lookSensitivity, -Self.maxPitch), Self.maxPitch)
        }
    }

    func setMove(_ v: SIMD2<Float>) {
        let len = simd_length(v)
        // Small dead zone so a resting thumb doesn't drift.
        let adjusted = len < 0.08 ? .zero : v / max(len, 1) * min(len, 1)
        lock.withLock { move = adjusted }
    }

    /// Step forward or back by a distance in metres (VoiceOver adjustable action).
    func nudge(forward distance: Float) {
        lock.withLock {
            let dir = SIMD3(-sin(yaw), 0, -cos(yaw))
            position = resolve(position + dir * distance)
        }
        applyCamera()
    }

    // MARK: Per frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.1))
        lastTime = time
        if move != .zero {
            let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let velocity = (forward * move.y + right * move.x) * Self.walkSpeed
            position = resolve(position + velocity * dt)
        }
        lock.unlock()
        applyCamera()
    }

    private func applyCamera() {
        lock.lock()
        let p = position, y = yaw, pt = pitch
        lock.unlock()
        let q = simd_quatf(angle: y, axis: [0, 1, 0]) * simd_quatf(angle: pt, axis: [1, 0, 0])
        cameraNode.simdPosition = p
        cameraNode.simdOrientation = q
    }

    // MARK: Collision (call with the lock held)

    /// Pushes the point out of any wall within body radius. Doors and openings stay passable.
    private func resolve(_ target: SIMD3<Float>) -> SIMD3<Float> {
        guard !walls.isEmpty else { return target }
        var p = SIMD2(target.x, target.z)
        for _ in 0..<3 {
            var moved = false
            for (a, b) in walls {
                let q = Self.closest(on: a, b, to: p)
                let d = p - q
                let dist = simd_length(d)
                guard dist < Self.radius, dist > 1e-5 else { continue }
                if gaps.contains(where: { Self.distance(from: q, toSegment: $0.0, $0.1) < 0.12 }) { continue }
                p += d / dist * (Self.radius - dist)
                moved = true
            }
            if !moved { break }
        }
        return SIMD3(p.x, target.y, p.y)
    }

    private static func closest(on a: SIMD2<Float>, _ b: SIMD2<Float>, to p: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        guard len2 > 1e-9 else { return a }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return a + ab * t
    }

    private static func distance(from p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_length(p - closest(on: a, b, to: p))
    }
}
