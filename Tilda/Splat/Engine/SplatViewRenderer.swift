import CoreGraphics
import Foundation
import Metal
import MetalSplatter
import SplatIO
import UIKit
import simd

/// Draws chosen views of one splat into offscreen pictures, so the fixture detector can look at the room from cameras we
/// pick. Load once, draw any number of views, then call `finish()` to release the splat.
///
/// A view is a `FixturePlacement.Camera` (ARKit convention). The projection matrix is built from the same intrinsics, so
/// pixel (u, v) of the picture is exactly the sensor pixel `FixturePlacement.ray` casts a ray through.
/// Never run this while splat training is running: both are heavy GPU jobs.
final class SplatViewRenderer: @unchecked Sendable {
    enum RenderError: Error { case noGPU, empty, sortTimeout, renderFailed }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var renderer: SplatRenderer?
    private let lock = NSLock()
    private var sorts = 0
    private var color: MTLTexture?
    private var depth: MTLTexture?

    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    static let near: Float = 0.05
    static let far: Float = 60

    /// Reads the splat file in slices (one slice of heavy structs in memory at a time) and uploads it.
    init(url: URL) async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.noGPU }
        self.device = device
        self.queue = queue
        let renderer = try SplatRenderer(device: device, colorFormat: Self.colorFormat, depthFormat: .depth32Float,
                                         sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 3,
                                         clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        let reader = try AutodetectSceneReader(url)
        var pending: [SplatPoint] = []
        var any = false
        for try await batch in try await reader.read() {
            try Task.checkCancellation()
            pending.append(contentsOf: batch)
            if pending.count >= 200_000 {
                await renderer.addChunk(try SplatChunk(device: device, from: pending))
                pending.removeAll(keepingCapacity: true)
                any = true
            }
        }
        if !pending.isEmpty { await renderer.addChunk(try SplatChunk(device: device, from: pending)); any = true }
        guard any else { throw RenderError.empty }
        renderer.onSortComplete = { [weak self] _ in self?.sortFinished() }
        self.renderer = renderer
    }

    /// Releases the splat and the textures. Also stops the sorter, which otherwise keeps polling for ever.
    func finish() async {
        let r = renderer
        renderer = nil
        r?.onSortComplete = nil
        await r?.removeAllChunks()
        color = nil
        depth = nil
    }

    private func sortFinished() { lock.lock(); sorts += 1; lock.unlock() }
    private var sortCount: Int { lock.lock(); defer { lock.unlock() }; return sorts }

    // MARK: Projection

    /// Metal clip-space projection for a pinhole camera in ARKit convention (looks down -Z, +Y up). Clip y is up and
    /// image v is down, which the principal point terms take care of; no extra flip is needed because the first texture
    /// row is the top of the picture.
    static func projection(for c: FixturePlacement.Camera, near: Float = near, far: Float = far) -> simd_float4x4 {
        let xs = 2 * c.fx / c.width, ys = 2 * c.fy / c.height
        let ox = 2 * c.cx / c.width - 1, oy = 1 - 2 * c.cy / c.height
        let zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(-ox, -oy, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }

    /// Where a world point lands in the picture (pixels, origin top-left), by the projection and view matrices.
    static func pixel(of world: SIMD3<Float>, camera c: FixturePlacement.Camera) -> SIMD2<Float>? {
        let clip = projection(for: c) * c.transform.inverse * SIMD4(world, 1)
        guard clip.w > 0 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2((ndc.x + 1) / 2 * c.width, (1 - ndc.y) / 2 * c.height)
    }

    // MARK: Drawing

    /// The view as an upright sRGB picture. Waits for the splat sort for this camera before drawing the final frame.
    func image(for camera: FixturePlacement.Camera) async throws -> CGImage {
        guard let renderer else { throw RenderError.renderFailed }
        let w = Int(camera.width), h = Int(camera.height)
        try prepareTextures(width: w, height: h)
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
            projectionMatrix: Self.projection(for: camera), viewMatrix: camera.transform.inverse, screenSize: SIMD2(w, h))

        // The sorter orders splats by distance from the camera and works in the background. A draw tells it the new
        // camera; the sort that finishes after the second draw is certain to be for this camera, even when one for the
        // previous view was still running at the first.
        for _ in 0..<2 {
            let before = sortCount
            _ = try await draw(descriptor, with: renderer)
            try await waitForSort(after: before)
        }
        for _ in 0..<40 {
            if try await draw(descriptor, with: renderer) { return try readImage(width: w, height: h) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RenderError.renderFailed
    }

    private func prepareTextures(width: Int, height: Int) throws {
        if let color, color.width == width, color.height == height, depth != nil { return }
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        c.usage = [.renderTarget, .shaderRead]
        c.storageMode = .shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        guard let ct = device.makeTexture(descriptor: c), let dt = device.makeTexture(descriptor: d) else { throw RenderError.renderFailed }
        color = ct
        depth = dt
    }

    /// One frame, drawn and finished. False when the renderer had nothing to draw yet (no sort has completed).
    private func draw(_ descriptor: SplatRenderer.ViewportDescriptor, with renderer: SplatRenderer) async throws -> Bool {
        guard let color, let depth, let buffer = queue.makeCommandBuffer() else { throw RenderError.renderFailed }
        let drew = try renderer.render(viewports: [descriptor], colorTexture: color, colorStoreAction: .store,
                                       depthTexture: depth, rasterizationRateMap: nil, renderTargetArrayLength: 0, to: buffer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            buffer.addCompletedHandler { _ in continuation.resume() }
            buffer.commit()
        }
        return drew
    }

    private func waitForSort(after count: Int, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while sortCount <= count {
            try Task.checkCancellation()
            if Date() > deadline { throw RenderError.sortTimeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func readImage(width: Int, height: Int) throws -> CGImage {
        guard let color else { throw RenderError.renderFailed }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // BGRA bytes are a little-endian ARGB word; the alpha channel is skipped (the background is opaque black).
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw RenderError.renderFailed }
        return image
    }
}

#if DEBUG
extension SplatViewRenderer {
    /// A camera at `position` looking at `target`, with no roll, using the planner's lens.
    static func lookCamera(from position: SIMD3<Float>, at target: SIMD3<Float>) -> FixturePlacement.Camera {
        SplatViewPlanner.camera(position: position, forward: target - position)
    }

    /// Device-free: the render projection and `FixturePlacement.Camera` agree on where a world point is, and a box drawn
    /// there places back at that point.
    static func projectionSelfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // Pixel by intrinsics, straight from the camera model `FixturePlacement.ray` inverts.
        func pinhole(_ p: SIMD3<Float>, _ c: FixturePlacement.Camera) -> SIMD2<Float> {
            let l = c.transform.inverse * SIMD4(p, 1)
            return SIMD2(c.cx + c.fx * l.x / -l.z, c.cy - c.fy * l.y / -l.z)
        }

        // A wall camera and a ceiling camera, both turned off-axis, and a point in each one's view.
        let wall = SplatViewPlanner.camera(position: [2.5, 0.9, 2.0],
                                           forward: SIMD3(0.3 * cos(0.35), -sin(0.35), -cos(0.35) * 0.95))
        let ceiling = SplatViewPlanner.camera(position: [1, 1.3, 1], forward: SIMD3(cos(1.2) * 0.8, sin(1.2), cos(1.2) * 0.6))
        let room = FixturePlacement.Room(floorY: 0, ceilingY: 2.4, walls: [.init(start: [-10, 0], end: [10, 0])])
        struct Case { var camera: FixturePlacement.Camera; var world: SIMD3<Float>; var surface: Fixture.Surface }
        let cases = [
            Case(camera: wall, world: [2.2, 0.55, 0], surface: .wall),
            Case(camera: wall, world: [3.4, 0.8, 0], surface: .wall),
            Case(camera: ceiling, world: [1.9, 2.4, 1.8], surface: .ceiling),
            Case(camera: ceiling, world: [1.5, 2.4, 1.3], surface: .ceiling),
        ]
        for (i, t) in cases.enumerated() {
            guard let px = pixel(of: t.world, camera: t.camera) else { failures.append("case \(i): point is behind the camera"); continue }
            expect(simd_distance(px, pinhole(t.world, t.camera)) < 0.01, "case \(i): render matrix and pinhole agree (\(px) vs \(pinhole(t.world, t.camera)))")
            expect(px.x > 0 && px.x < t.camera.width && px.y > 0 && px.y < t.camera.height, "case \(i): the point is in the picture (\(px))")
            // A box centred on that pixel, through the same path the detector uses, lands back on the point.
            let box = NormalizedBox(x: px.x / t.camera.width - 0.02, y: px.y / t.camera.height - 0.02, width: 0.04, height: 0.04)
            let placed = FixturePlacement.place(kind: .hvacVent, surface: t.surface, box: box, orientation: .up, camera: t.camera, room: room)
            expect(placed.map { simd_distance($0.position, t.world) < 0.02 } ?? false,
                   "case \(i): the box places back within 2 cm (got \(placed?.position ?? .zero), want \(t.world))")
        }

        // Handedness and the vertical flip: a point right of and above the view axis lands right of and above centre.
        let level = SplatViewPlanner.camera(position: [0, 1, 0], forward: [0, 0, -1])
        if let p = pixel(of: [0.5, 1.3, -2], camera: level) {
            expect(p.x > level.cx && p.y < level.cy, "right and up lands right of and above centre (\(p))")
            expect(abs(p.x - (level.cx + level.fx * 0.25)) < 0.01 && abs(p.y - (level.cy - level.fx * 0.15)) < 0.01, "level camera pixel is fx * x / z")
        } else { failures.append("level camera did not project") }

        // Perspective convention of the matrix: near maps to depth 0, far to 1.
        let proj = projection(for: level)
        let near = proj * SIMD4(0, 0, -Self.near, 1), far = proj * SIMD4(0, 0, -Self.far, 1)
        expect(abs(near.z / near.w) < 1e-4 && abs(far.z / far.w - 1) < 1e-4, "depth runs 0 at near to 1 at far")

        // The turn that puts a rendered view into a stored photo, so it displays upright through the keyframe loaders.
        failures += FixtureDetectorStorage.selfCheck()
        return failures
    }

    // MARK: Real render checks (need Metal, so they run from the app, not from `selfCheck`)

    /// Draws a synthetic splat with bright blobs at known world points and checks each lands on the pixel the projection
    /// predicts. Run with `-TildaSelfCheck`; the result is logged.
    static func renderSelfCheck() async -> [String] {
        var failures: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tilda-view-check", isDirectory: true)
        let url = dir.appendingPathComponent("blobs.ply")
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let blobs: [SIMD3<Float>] = [[3.0, 1.5, -1.0], [1.2, 0.4, -0.5], [-0.4, 1.9, 0.6]]
            var points: [SplatPoint] = []
            for b in blobs {
                points.append(SplatPoint(position: b, color: .sRGBUInt8(SIMD3<UInt8>(255, 255, 255)), opacity: .linearFloat(1),
                                         scale: .linearFloat(SIMD3(repeating: 0.05)), rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
            }
            let writer = try SplatPLYSceneWriter(toFileAtPath: url.path)
            try await writer.start(sphericalHarmonicDegree: 0, binary: true, pointCount: points.count)
            try await writer.write(points)
            try await writer.close()

            let renderer = try await SplatViewRenderer(url: url)
            // Two cameras with different turns (the second is yawed, pitched and still has no roll).
            let cameras = [lookCamera(from: [2.5, 1.2, 1.0], at: [2.5, 1.2, -1]),
                           lookCamera(from: [0.2, 1.6, 3.0], at: [1.5, 0.6, -1])]
            for (ci, camera) in cameras.enumerated() {
                let image = try await renderer.image(for: camera)
                if image.width != Int(camera.width) || image.height != Int(camera.height) { failures.append("camera \(ci): picture size") }
                var seen = 0
                for (bi, blob) in blobs.enumerated() {
                    guard let want = pixel(of: blob, camera: camera), want.x > 80, want.x < camera.width - 80,
                          want.y > 80, want.y < camera.height - 80 else { continue }
                    seen += 1
                    guard let got = brightCentroid(image, near: want, radius: 70) else {
                        failures.append("camera \(ci): blob \(bi) not found near \(want)"); continue
                    }
                    let error = simd_distance(got, want)
                    NSLog("view render check: camera %d blob %d predicted %@ found %@ (%.2f px)", ci, bi, "\(want)", "\(got)", error)
                    if error > 1.5 { failures.append("camera \(ci): blob \(bi) is \(error) px from where the projection puts it") }
                }
                if seen == 0 { failures.append("camera \(ci): no blob in view to check") }
            }
            await renderer.finish()
        } catch {
            failures.append("render failed: \(error)")
        }
        return failures
    }

    /// Brightness-weighted centre of the lit pixels within `radius` of `point`.
    private static func brightCentroid(_ image: CGImage, near point: SIMD2<Float>, radius: Int) -> SIMD2<Float>? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // CGContext rows run top to bottom in memory here
        var sum = SIMD2<Double>.zero, weight = 0.0
        for y in max(0, Int(point.y) - radius)..<min(h, Int(point.y) + radius) {
            for x in max(0, Int(point.x) - radius)..<min(w, Int(point.x) + radius) {
                let v = Double(rgba[(y * w + x) * 4 + 1])
                if v > 25 { sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5) * v; weight += v }
            }
        }
        return weight > 0 ? SIMD2(Float(sum.x / weight), Float(sum.y / weight)) : nil
    }

    /// Plans views for the synthetic sample room, draws them and saves them as JPEGs in `directory`, to look at. Also saves
    /// the first one as it is stored for the photo screens. Run with `-TildaSplatViews <directory>`.
    static func writeSampleViews(to directory: URL) async {
        let ply = FileManager.default.temporaryDirectory.appendingPathComponent("tilda-sample-views/splat.ply")
        await SplatDebugSample.write(to: ply)
        // The sample is a 5 x 4 m room, 2.5 m high, floor at y = 0, walked on a grid.
        let walls = SplatViewPlanner.rectangle(width: 5, depth: 4)
        let views = SplatViewPlanner.plan(walls: walls, floorY: 0, ceilingHeight: 2.5, keyframes: SplatViewPlanner.walkedGrid(width: 5, depth: 4))
        NSLog("sample views: %d planned", views.count)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let renderer = try await SplatViewRenderer(url: ply)
            let started = Date()
            for (i, view) in views.enumerated() {
                let image = try await renderer.image(for: view.camera)
                let name = String(format: "%@_%03d.jpg", view.kind == .wall ? "wall" : "ceiling", i + 1)
                try UIImage(cgImage: image).jpegData(compressionQuality: 0.9)?.write(to: directory.appendingPathComponent(name))
                if i == 0 { _ = FixtureDetectorStorage.writeJPEG(upright: image, to: directory.appendingPathComponent("stored_" + name)) }
            }
            NSLog("sample views: wrote %d in %.1f s to %@", views.count, Date().timeIntervalSince(started), directory.path)
            await renderer.finish()
        } catch {
            NSLog("sample views failed: %@", "\(error)")
        }
    }
}
#endif
