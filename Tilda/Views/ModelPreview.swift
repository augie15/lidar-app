import SceneKit
import SwiftUI

/// Interactive 3D preview of a scan: drag to orbit, pinch to zoom.
struct ModelPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(Theme.card)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        context.coordinator.url = url
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        load(into: view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var url: URL? }

    private func load(into view: SCNView, coordinator: Coordinator) {
        // Point clouds (PLY with no faces) are read by our own parser: SceneKit's loader turns them into bogus triangles.
        if url.pathExtension.lowercased() == "ply" {
            view.scene = SCNScene()
            loadPointCloud(into: view, coordinator: coordinator)
            return
        }
        let scene = (try? SCNScene(url: url, options: [.checkConsistency: false])) ?? SCNScene()
        Self.prepareMaterials(in: scene)
        view.scene = scene
        view.pointOfView = Self.framingCamera(for: scene)
    }

    /// Reads the PLY off the main thread (a big cloud is tens of MB), then shows it as colored points.
    private func loadPointCloud(into view: SCNView, coordinator: Coordinator) {
        let source = url
        Task.detached(priority: .userInitiated) { [weak view] in
            guard let cloud = try? PLYPointCloud.read(source), cloud.count > 0 else { return }
            let geometry = PointGeometry.make(from: cloud)
            await MainActor.run {
                guard let view, coordinator.url == source else { return }
                let scene = SCNScene()
                scene.rootNode.addChildNode(SCNNode(geometry: geometry))
                view.scene = scene
                view.pointOfView = Self.framingCamera(for: scene)
            }
        }
    }

    /// Makes vertex colors visible and surfaces double sided. Falls back to soft grey only when a geometry has neither
    /// vertex colors nor a texture. Shared with the walkthrough.
    static func prepareMaterials(in scene: SCNScene) {
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let hasVertexColors = !geometry.sources(for: .color).isEmpty
            geometry.materials.forEach { material in
                let contents = material.diffuse.contents
                let hasTexture = contents != nil && !(contents is UIColor)
                if hasVertexColors && !hasTexture {
                    // White diffuse lets the per-vertex color through unchanged.
                    material.diffuse.contents = UIColor.white
                } else if !hasVertexColors && !hasTexture {
                    material.diffuse.contents = contents ?? UIColor(white: 0.82, alpha: 1)
                }
                material.isDoubleSided = true
            }
        }
    }

    /// Places a camera on a 3/4 view far enough back to fit the model's bounding sphere.
    private static func framingCamera(for scene: SCNScene) -> SCNNode {
        let (minB, maxB) = scene.rootNode.boundingBox
        let center = SIMD3<Float>(Float(minB.x + maxB.x), Float(minB.y + maxB.y), Float(minB.z + maxB.z)) / 2
        let extent = SIMD3<Float>(Float(maxB.x - minB.x), Float(maxB.y - minB.y), Float(maxB.z - minB.z))
        let radius = max(simd_length(extent) / 2, 0.05)

        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 100
        let distance = radius / sin(Float(camera.fieldOfView / 2) * .pi / 180) * 1.1

        let node = SCNNode()
        node.camera = camera
        let direction = simd_normalize(SIMD3<Float>(0.6, 0.5, 1))
        node.simdPosition = center + direction * distance
        node.simdLook(at: center)
        scene.rootNode.addChildNode(node)
        return node
    }
}
