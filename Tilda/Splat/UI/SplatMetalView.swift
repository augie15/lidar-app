import MetalKit
import MetalSplatter
import SplatIO
import SwiftUI
import UIKit
import simd

/// Bounds of a loaded splat, measured with the stray outliers left out so one far-off splat can't push the camera away.
struct SplatBounds: Equatable {
    var center: SIMD3<Float>
    var radius: Float
    var count: Int
}

enum SplatLoadError: LocalizedError {
    case empty
    case noGPU
    var errorDescription: String? {
        switch self {
        case .empty: "This file has no splats in it."
        case .noGPU: "This device can't draw 3D photos."
        }
    }
}

/// Orbit camera around a target, +Y up. The splat itself may be turned upside down with `flipped`, because a file
/// from the trainer can come out with its up axis reversed.
struct SplatCamera: Equatable {
    var target = SIMD3<Float>.zero
    var yaw: Float = 0.6
    var pitch: Float = 0.3
    var distance: Float = 4

    static let fovy: Float = 60 * .pi / 180

    func eye() -> SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    func view() -> simd_float4x4 {
        lookAt(eye: eye(), target: target, up: SIMD3(0, 1, 0))
    }

    /// Rooms start inside, near the middle, because their walls are solid from outside and would hide everything.
    /// Objects start outside, far enough back to fit the whole thing on a portrait screen.
    static func home(for bounds: SplatBounds, flipped: Bool, inside: Bool, aspect: Float) -> SplatCamera {
        let center = flipped ? SIMD3(-bounds.center.x, -bounds.center.y, bounds.center.z) : bounds.center
        if inside {
            return SplatCamera(target: center, yaw: 0.5, pitch: 0.08, distance: max(bounds.radius * 0.5, 0.3))
        }
        let half = atan(tan(fovy / 2) * min(1, aspect))
        return SplatCamera(target: center, yaw: 0.6, pitch: 0.28, distance: max(bounds.radius / sin(half) * 1.05, 0.5))
    }
}

private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0),
                                   SIMD4(s.z, u.z, -f.z, 0),
                                   SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
}

private func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1),
                                   SIMD4(0, 0, zs * near, 0)))
}

/// Reports what the viewer is doing to SwiftUI.
@MainActor
@Observable
final class SplatViewerModel {
    enum State: Equatable { case loading, ready(SplatBounds), failed(String) }
    private(set) var state: State = .loading
    fileprivate(set) var splatCount = 0

    fileprivate func set(_ state: State) { self.state = state }
}

/// Draws one splat file. Rendering is on demand: the view redraws when the camera moves or a sort finishes, so a still
/// scene costs nothing.
struct SplatMetalView: UIViewRepresentable {
    let url: URL
    let flipped: Bool
    let startsInside: Bool
    let model: SplatViewerModel
    /// Bumped by the SwiftUI side to ask for a reset (the reset button and VoiceOver action).
    let commands: SplatViewerCommands

    func makeCoordinator() -> Coordinator { Coordinator(model: model, commands: commands) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        let c = context.coordinator
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = c
        c.attach(view)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .adjustable
        view.accessibilityLabel = "3D photo"
        view.accessibilityHint = "Swipe up or down to zoom. Use the actions rotor to turn or reset the view."
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Reset view") { [weak c] _ in c?.resetCamera(animated: true); return true },
            UIAccessibilityCustomAction(name: "Turn left") { [weak c] _ in c?.nudge(yaw: -0.5); return true },
            UIAccessibilityCustomAction(name: "Turn right") { [weak c] _ in c?.nudge(yaw: 0.5); return true },
            UIAccessibilityCustomAction(name: "Look up") { [weak c] _ in c?.nudge(pitch: 0.3); return true },
            UIAccessibilityCustomAction(name: "Look down") { [weak c] _ in c?.nudge(pitch: -0.3); return true },
        ]
        c.startsInside = startsInside
        c.load(url: url, flipped: flipped)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setFlipped(flipped)
        context.coordinator.commands.reset = { [weak c = context.coordinator] in c?.resetCamera(animated: true) }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { coordinator.teardown() }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        let model: SplatViewerModel
        let commands: SplatViewerCommands
        private weak var view: MTKView?
        private var queue: MTLCommandQueue?
        private var renderer: SplatRenderer?
        private var bounds: SplatBounds?
        private var camera = SplatCamera()
        private var flipped = false
        var startsInside = false
        private var aspect: Float { drawableSize.height > 0 ? Float(drawableSize.width / drawableSize.height) : 0.5 }
        private var drawableSize: CGSize = .zero
        private var loadTask: Task<Void, Never>?
        private var link: CADisplayLink?
        private var anim: (from: SplatCamera, to: SplatCamera, start: CFTimeInterval)?
        private let inFlight = DispatchSemaphore(value: 3)
        /// Redraws allowed after the last touch, to let the sorter catch up without looping forever.
        private var settleDraws = 0
        private var pinchStart: Float = 1

        init(model: SplatViewerModel, commands: SplatViewerCommands) {
            self.model = model
            self.commands = commands
        }

        func attach(_ view: MTKView) {
            self.view = view
            queue = view.device?.makeCommandQueue()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
            pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
            tap.numberOfTapsRequired = 2
            for g in [pan, pan2, pinch, tap] as [UIGestureRecognizer] { g.delegate = self; view.addGestureRecognizer(g) }
            commands.reset = { [weak self] in self?.resetCamera(animated: true) }
        }

        func teardown() {
            loadTask?.cancel()
            link?.invalidate()
            renderer?.onSortComplete = nil
            // MetalSplatter's sort loop holds the chunk buffers until they are removed; without this every closed
            // viewer would keep its splat (hundreds of MB) alive.
            if let renderer { Task { await renderer.removeAllChunks() } }
            renderer = nil
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Loading

        func load(url: URL, flipped: Bool) {
            self.flipped = flipped
            guard let view, let device = view.device else { model.set(.failed(SplatLoadError.noGPU.localizedDescription)); return }
            let colorFormat = view.colorPixelFormat, depthFormat = view.depthStencilPixelFormat
            loadTask = Task { [weak self] in
                do {
                    let renderer = try SplatRenderer(device: device, colorFormat: colorFormat, depthFormat: depthFormat,
                                                     sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 3)
                    let (positions, chunks) = try await Self.read(url: url, device: device)
                    guard !Task.isCancelled, let self else { return }
                    guard !chunks.isEmpty, let bounds = Self.measure(positions) else { throw SplatLoadError.empty }
                    for chunk in chunks { await renderer.addChunk(chunk) }
                    guard !Task.isCancelled else { return }
                    renderer.onSortComplete = { [weak self] _ in
                        DispatchQueue.main.async { self?.sortFinished() }
                    }
                    self.renderer = renderer
                    self.bounds = bounds
                    self.model.splatCount = bounds.count
                    self.camera = SplatCamera.home(for: bounds, flipped: self.flipped, inside: self.startsInside, aspect: self.aspect)
                    self.model.set(.ready(bounds))
                    self.redraw(settle: 3)
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.model.set(.failed(error.localizedDescription)) }
                }
            }
        }

        /// Reads the file in slices so only one slice of heavy splat structs is in memory at a time.
        nonisolated private static func read(url: URL, device: MTLDevice) async throws -> ([SIMD3<Float>], [SplatChunk]) {
            let reader = try AutodetectSceneReader(url)
            var positions: [SIMD3<Float>] = []
            var chunks: [SplatChunk] = []
            var pending: [SplatPoint] = []
            let sliceSize = 200_000
            for try await batch in try await reader.read() {
                try Task.checkCancellation()
                pending.append(contentsOf: batch)
                positions.append(contentsOf: batch.map(\.position))
                if pending.count >= sliceSize {
                    chunks.append(try SplatChunk(device: device, from: pending))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty { chunks.append(try SplatChunk(device: device, from: pending)) }
            return (positions, chunks)
        }

        /// Centre and radius from the 2nd to 98th percentile on each axis.
        nonisolated private static func measure(_ all: [SIMD3<Float>]) -> SplatBounds? {
            let pts = all.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            guard !pts.isEmpty else { return nil }
            func range(_ key: (SIMD3<Float>) -> Float) -> (Float, Float) {
                // Sampling keeps this quick on millions of splats.
                let step = max(1, pts.count / 50_000)
                let v = stride(from: 0, to: pts.count, by: step).map { key(pts[$0]) }.sorted()
                return (v[Int(Float(v.count - 1) * 0.02)], v[Int(Float(v.count - 1) * 0.98)])
            }
            let x = range(\.x), y = range(\.y), z = range(\.z)
            let lo = SIMD3(x.0, y.0, z.0), hi = SIMD3(x.1, y.1, z.1)
            return SplatBounds(center: (lo + hi) / 2, radius: max(simd_length(hi - lo) / 2, 0.1), count: pts.count)
        }

        // MARK: Camera

        func setFlipped(_ value: Bool) {
            guard value != flipped else { return }
            flipped = value
            resetCamera(animated: false)
        }

        func resetCamera(animated: Bool) {
            guard let bounds else { return }
            let home = SplatCamera.home(for: bounds, flipped: flipped, inside: startsInside, aspect: aspect)
            if animated && !UIAccessibility.isReduceMotionEnabled {
                anim = (camera, home, CACurrentMediaTime())
                if link == nil {
                    let l = CADisplayLink(target: self, selector: #selector(step))
                    l.add(to: .main, forMode: .common)
                    link = l
                }
            } else {
                anim = nil
                camera = home
                redraw()
            }
        }

        @objc private func step() {
            guard let anim else { link?.invalidate(); link = nil; return }
            let t = min(1, Float((CACurrentMediaTime() - anim.start) / 0.4))
            let e = 1 - pow(1 - t, 3)
            // Take the short way round in yaw.
            var dyaw = anim.to.yaw - anim.from.yaw
            dyaw -= (dyaw / (2 * .pi)).rounded() * 2 * .pi
            camera = SplatCamera(target: simd_mix(anim.from.target, anim.to.target, SIMD3(repeating: e)),
                                 yaw: anim.from.yaw + dyaw * e,
                                 pitch: anim.from.pitch + (anim.to.pitch - anim.from.pitch) * e,
                                 distance: anim.from.distance + (anim.to.distance - anim.from.distance) * e)
            redraw()
            if t >= 1 { self.anim = nil; link?.invalidate(); link = nil }
        }

        func nudge(yaw: Float = 0, pitch: Float = 0) {
            camera.yaw += yaw
            camera.pitch = min(max(camera.pitch + pitch, -1.45), 1.45)
            redraw(settle: 3)
        }

        private func interrupt() { anim = nil }

        @objc private func orbit(_ g: UIPanGestureRecognizer) {
            guard bounds != nil, let view else { return }
            interrupt()
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            camera.yaw -= Float(t.x) * 0.0055
            camera.pitch = min(max(camera.pitch + Float(t.y) * 0.0055, -1.45), 1.45)
            redraw(settle: 3)
        }

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let bounds, let view else { return }
            interrupt()
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            let v = camera.view()
            let right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
            let up = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
            // One screen height covers the visible height at the target's distance.
            let perPixel = 2 * camera.distance * tan(SplatCamera.fovy / 2) / Float(max(view.bounds.height, 1))
            camera.target += (-right * Float(t.x) + up * Float(t.y)) * perPixel
            let off = camera.target - (flipped ? SIMD3(-bounds.center.x, -bounds.center.y, bounds.center.z) : bounds.center)
            if simd_length(off) > bounds.radius * 2 { camera.target -= off * (1 - bounds.radius * 2 / simd_length(off)) }
            redraw(settle: 3)
        }

        @objc private func zoom(_ g: UIPinchGestureRecognizer) {
            guard let bounds else { return }
            interrupt()
            if g.state == .began { pinchStart = camera.distance }
            let d = pinchStart / Float(max(g.scale, 0.05))
            camera.distance = min(max(d, bounds.radius * 0.05), bounds.radius * 12)
            redraw(settle: 3)
        }

        @objc private func doubleTap() { resetCamera(animated: true) }

        // MARK: Drawing

        private func redraw(settle: Int = 0) {
            settleDraws = settle
            view?.setNeedsDisplay()
        }

        private func sortFinished() {
            guard settleDraws > 0 else { return }
            settleDraws -= 1
            view?.setNeedsDisplay()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = size
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let renderer, let bounds, let queue, let drawable = view.currentDrawable else { return }
            let size = view.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            guard inFlight.wait(timeout: .now()) == .success else { view.setNeedsDisplay(); return }
            guard let buffer = queue.makeCommandBuffer() else { inFlight.signal(); return }
            let sem = inFlight
            buffer.addCompletedHandler { _ in sem.signal() }

            let proj = perspective(fovy: SplatCamera.fovy, aspect: Float(size.width / size.height),
                                   near: max(bounds.radius * 0.01, 0.005), far: bounds.radius * 60)
            // Turning the scene upside down is a half turn about Z (flips X and Y, keeps handedness).
            let orient = flipped ? simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))) : matrix_identity_float4x4
            let desc = SplatRenderer.ViewportDescriptor(
                viewport: MTLViewport(originX: 0, originY: 0, width: size.width, height: size.height, znear: 0, zfar: 1),
                projectionMatrix: proj, viewMatrix: camera.view() * orient,
                screenSize: SIMD2(Int(size.width), Int(size.height)))
            let drew = (try? renderer.render(viewports: [desc], colorTexture: drawable.texture,
                                             colorStoreAction: .store, depthTexture: view.depthStencilTexture,
                                             rasterizationRateMap: nil, renderTargetArrayLength: 0,
                                             to: buffer)) ?? false
            if drew { buffer.present(drawable) } else { view.setNeedsDisplay() }
            buffer.commit()
        }
    }
}

/// Lets the SwiftUI chrome ask the Metal view to reset.
final class SplatViewerCommands {
    var reset: () -> Void = {}
}
