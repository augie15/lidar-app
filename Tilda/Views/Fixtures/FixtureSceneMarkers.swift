import SceneKit
import SwiftUI
import UIKit
import simd

/// Fixture markers for SceneKit scenes (the scan page's 3D preview and the walk-through).
///
/// Each fixture becomes one node named `fixture-<uuid>` at its world position:
///   HVAC vent        thin rounded plate flat on its surface (upright on a wall, flat on a ceiling or floor)
///   Bathroom fan     disc on the ceiling
///   Baseboard heater low bar along the wall, as long as `length` (0.6 m when unknown)
/// Markers use a constant (unlit) material in the kind's colour and are drawn after the model with the depth test
/// off, so grey walls never hide them. An invisible sphere around each one makes it easy to tap.
enum FixtureSceneMarkers {
    static let containerName = "fixture-markers"
    private static let prefix = "fixture-"
    private static let hitPadName = "fixture-hit"

    /// Rebuilds all markers under one container node. Call again whenever the fixtures change. `throughWalls` draws them
    /// on top of everything (the orbit preview); the first-person walkthrough passes false so walls hide other rooms'.
    static func install(_ fixtures: [Fixture], walls: [FloorPlan.Segment], in scene: SCNScene,
                        visible: Bool = true, focused: UUID? = nil, throughWalls: Bool = true) {
        scene.rootNode.childNode(withName: containerName, recursively: false)?.removeFromParentNode()
        let container = SCNNode()
        container.name = containerName
        container.isHidden = !visible
        for f in fixtures { container.addChildNode(node(for: f, walls: walls, focused: f.id == focused, throughWalls: throughWalls)) }
        scene.rootNode.addChildNode(container)
    }

    static func setVisible(_ visible: Bool, in scene: SCNScene) {
        scene.rootNode.childNode(withName: containerName, recursively: false)?.isHidden = !visible
    }

    /// The fixture under a touch, if any: walks every node the touch passes through (the markers draw on top, so the
    /// walls behind them are irrelevant).
    static func fixtureID(at point: CGPoint, in view: SCNView) -> UUID? {
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                 .ignoreHiddenNodes: true])
        for hit in hits {
            var node: SCNNode? = hit.node
            while let n = node {
                if let name = n.name, name.hasPrefix(prefix), name != containerName, name != hitPadName,
                   let id = UUID(uuidString: String(name.dropFirst(prefix.count))) { return id }
                node = n.parent
            }
        }
        return nil
    }

    // MARK: Nodes

    static func node(for f: Fixture, walls: [FloorPlan.Segment], focused: Bool = false, throughWalls: Bool = true) -> SCNNode {
        let uiColor = UIColor(f.kind.color())
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = uiColor
        material.readsFromDepthBuffer = !throughWalls
        material.writesToDepthBuffer = false
        material.isDoubleSided = true

        let root = SCNNode()
        root.name = prefix + f.id.uuidString
        root.simdPosition = f.position

        let body = SCNNode()
        body.renderingOrder = throughWalls ? 1000 : 0
        let axis = f.axis ?? FixturePlacement.snapToWall(f.planPosition, walls: walls)?.axis ?? SIMD2(1, 0)
        // Rotation about Y that turns the node's local +X onto the wall direction (plan y is world z).
        let yaw = -atan2(axis.y, axis.x)

        switch (f.kind, f.surface) {
        case (.bathroomFan, _):
            let disc = SCNCylinder(radius: 0.3, height: 0.04)
            disc.materials = [material]
            body.geometry = disc
            if f.surface == .wall { body.eulerAngles = SCNVector3(Float.pi / 2, yaw, 0) }
        case (.baseboardHeater, _):
            let length = CGFloat(f.length ?? 0.6)
            let bar = SCNBox(width: length, height: 0.16, length: 0.07, chamferRadius: 0.035)
            bar.materials = [material]
            body.geometry = bar
            body.eulerAngles.y = yaw
        case (.hvacVent, .wall):
            let plate = SCNBox(width: 0.5, height: 0.3, length: 0.04, chamferRadius: 0.03)
            plate.materials = [material]
            body.geometry = plate
            body.eulerAngles.y = yaw
        case (.hvacVent, _):
            let plate = SCNBox(width: 0.5, height: 0.04, length: 0.3, chamferRadius: 0.018)
            plate.materials = [material]
            body.geometry = plate
        }
        root.addChildNode(body)

        // Bigger invisible target so a finger can hit a thin plate.
        let padMaterial = SCNMaterial()
        padMaterial.diffuse.contents = UIColor.clear
        padMaterial.transparency = 0.001
        padMaterial.readsFromDepthBuffer = false
        padMaterial.writesToDepthBuffer = false
        let padRadius = max(0.38, CGFloat((f.length ?? 0) / 2))
        let pad = SCNSphere(radius: padRadius)
        pad.materials = [padMaterial]
        let padNode = SCNNode(geometry: pad)
        padNode.name = hitPadName
        padNode.renderingOrder = 999
        root.addChildNode(padNode)

        // A white halo on unchecked detections would be noise; the focused one (arriving from the editor) pulses.
        if focused {
            let ring = SCNTorus(ringRadius: max(0.4, padRadius), pipeRadius: 0.012)
            let ringMaterial = SCNMaterial()
            ringMaterial.lightingModel = .constant
            ringMaterial.diffuse.contents = UIColor.white
            ringMaterial.emission.contents = UIColor.white
            ringMaterial.readsFromDepthBuffer = false
            ringMaterial.writesToDepthBuffer = false
            ring.materials = [ringMaterial]
            let ringNode = SCNNode(geometry: ring)
            ringNode.renderingOrder = 1001
            // Torus lies flat; stand it up for wall units so it faces the room.
            if f.surface == .wall { ringNode.eulerAngles = SCNVector3(Float.pi / 2, yaw, 0) }
            ringNode.runAction(.repeatForever(.sequence([
                .group([.scale(to: 1.25, duration: 0.7), .fadeOpacity(to: 0.35, duration: 0.7)]),
                .group([.scale(to: 1, duration: 0.7), .fadeOpacity(to: 1, duration: 0.7)]),
            ])))
            root.addChildNode(ringNode)
        }
        return root
    }
}
