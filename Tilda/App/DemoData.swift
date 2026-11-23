#if DEBUG
import Foundation
import SceneKit
import UIKit
import simd

/// Debug-only sample library for Simulator screenshots, where scanning is unavailable.
/// Launch with `-TildaDemoData` to replace the library with two room scans (one room and a merged floor) written in
/// the same format the Room scanner saves: a RoomPlan-style box model, `floorplan.json` and `roomfacts.json`.
/// Not compiled into Release builds.
enum DemoData {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-TildaDemoData") }

    private struct RoomSpec {
        let label: String
        let min: SIMD2<Float>
        let max: SIMD2<Float>
        var size: SIMD2<Float> { max - min }
    }

    private struct Furniture {
        let category: String
        let center: SIMD2<Float>
        let size: SIMD2<Float>   // width, depth
        let height: Float
        let rotation: Float
    }

    private static let ceiling: Float = 2.59
    private static let wall: Float = 0.15

    static func seed(into root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let living = RoomSpec(label: "living room", min: [0, 0], max: [5.4, 4.2])
        let bedroom = RoomSpec(label: "bedroom", min: [-3.4, 0], max: [0, 4.2])
        let kitchen = RoomSpec(label: "kitchen", min: [2.4, 4.2], max: [5.4, 7.8])

        let livingFurniture = [
            Furniture(category: "sofa", center: [2.7, 3.6], size: [2.2, 0.95], height: 0.85, rotation: 0),
            Furniture(category: "table", center: [2.7, 2.45], size: [1.1, 0.6], height: 0.45, rotation: 0),
            Furniture(category: "storage", center: [2.7, 0.26], size: [1.8, 0.45], height: 0.6, rotation: 0),
            Furniture(category: "television", center: [2.7, 0.2], size: [1.4, 0.1], height: 0.8, rotation: 0),
            Furniture(category: "chair", center: [0.95, 1.5], size: [0.8, 0.8], height: 0.9, rotation: 0.5),
            Furniture(category: "table", center: [4.75, 3.65], size: [0.5, 0.5], height: 0.55, rotation: 0),
        ]
        let bedroomFurniture = [
            Furniture(category: "bed", center: [-1.7, 2.9], size: [1.55, 2.05], height: 0.6, rotation: 0),
            Furniture(category: "storage", center: [-3.1, 1.0], size: [0.5, 1.2], height: 1.9, rotation: 0),
            Furniture(category: "table", center: [-0.55, 3.8], size: [0.45, 0.4], height: 0.55, rotation: 0),
        ]
        let kitchenFurniture = [
            Furniture(category: "storage", center: [5.1, 6.0], size: [0.6, 3.6], height: 0.9, rotation: 0),
            Furniture(category: "refrigerator", center: [2.75, 7.45], size: [0.7, 0.7], height: 1.8, rotation: 0),
            Furniture(category: "sink", center: [5.1, 6.6], size: [0.6, 0.8], height: 0.9, rotation: 0),
            Furniture(category: "oven", center: [5.1, 5.2], size: [0.6, 0.6], height: 0.9, rotation: 0),
            Furniture(category: "table", center: [3.6, 5.9], size: [1.2, 0.8], height: 0.75, rotation: 0),
        ]

        // Single room, scanned yesterday.
        var livingPlan = FloorPlan()
        livingPlan.walls = walls(of: living)
        livingPlan.doors = [seg([0, 3.0], [0, 3.9])]
        livingPlan.windows = [seg([1.0, 0], [2.3, 0]), seg([3.1, 0], [4.4, 0])]
        livingPlan.openings = [seg([3.8, 4.2], [5.0, 4.2])]
        livingPlan.objects = livingFurniture.map(box)
        let livingFacts = RoomFacts(rooms: [facts(living, livingFurniture, doors: 1, windows: 2, openings: 1,
                                                  openingArea: 0.9 * 2.03 + 2 * 1.3 * 1.3 + 1.2 * 2.1)],
                                    wallThickness: wall,
                                    totalGrossArea: grossArea(living))
        let livingFixtures = [
            fixture(.hvacVent, .floor, [1.2, 2.6]),
            fixture(.hvacVent, .ceiling, [2.7, 1.8], confidence: 0.82),
            fixture(.baseboardHeater, .wall, [1.65, 0.1], length: 1.3, axis: [1, 0]),
            fixture(.baseboardHeater, .wall, [3.75, 0.1], length: 1.3, axis: [1, 0]),
        ]
        write(name: "Living room", plan: livingPlan, facts: livingFacts, rooms: [living],
              furniture: livingFurniture, fixtures: livingFixtures,
              date: .now.addingTimeInterval(-26 * 3600), root: root)

        // Whole floor, three rooms merged, scanned today.
        var floorPlan = FloorPlan()
        floorPlan.walls = walls(of: living) + walls(of: bedroom).filter { $0.start.x != 0 || $0.end.x != 0 }
            + walls(of: kitchen).filter { !($0.start.y == 4.2 && $0.end.y == 4.2) }
        floorPlan.doors = [seg([0, 3.0], [0, 3.9]), seg([-3.4, 3.1], [-3.4, 4.0]), seg([5.4, 7.0], [5.4, 7.8])]
        floorPlan.windows = [seg([1.0, 0], [2.3, 0]), seg([3.1, 0], [4.4, 0]), seg([-2.6, 0], [-1.2, 0]),
                             seg([3.4, 7.8], [4.6, 7.8])]
        floorPlan.openings = [seg([3.8, 4.2], [5.0, 4.2])]
        let allFurniture = livingFurniture + bedroomFurniture + kitchenFurniture
        floorPlan.objects = allFurniture.map(box)
        let floorFacts = RoomFacts(
            rooms: [
                facts(living, livingFurniture, doors: 1, windows: 2, openings: 1,
                      openingArea: 0.9 * 2.03 + 2 * 1.3 * 1.3 + 1.2 * 2.1),
                facts(kitchen, kitchenFurniture, doors: 1, windows: 1, openings: 1,
                      openingArea: 0.9 * 2.03 + 1.2 * 1.1 + 1.2 * 2.1),
                facts(bedroom, bedroomFurniture, doors: 2, windows: 1, openings: 0,
                      openingArea: 2 * 0.9 * 2.03 + 1.4 * 1.3),
            ],
            wallThickness: wall,
            // Interior floor + exterior walls in full (33.2 m outline) + shared walls once (7.2 m).
            totalGrossArea: (5.4 * 4.2 + 3.4 * 4.2 + 3.0 * 3.6) + 33.2 * wall + 4 * wall * wall + 7.2 * wall)
        let floorFixtures = livingFixtures + [
            fixture(.hvacVent, .ceiling, [-1.7, 2.0], confidence: 0.9),
            fixture(.baseboardHeater, .wall, [-1.9, 0.1], length: 1.2, axis: [1, 0]),
            fixture(.bathroomFan, .ceiling, [-0.7, 3.4], confidence: 0.77),
            fixture(.bathroomFan, .ceiling, [3.9, 5.6], source: .manual),
            fixture(.hvacVent, .floor, [3.3, 7.3]),
        ]
        write(name: "Main floor", plan: floorPlan, facts: floorFacts, rooms: [living, bedroom, kitchen],
              furniture: allFurniture, fixtures: floorFixtures,
              date: .now.addingTimeInterval(-40 * 60), root: root)
    }

    // MARK: - Facts

    private static func facts(_ room: RoomSpec, _ items: [Furniture], doors: Int, windows: Int, openings: Int,
                              openingArea: Float) -> RoomFacts.Room {
        let floor = room.size.x * room.size.y
        let perimeter = 2 * (room.size.x + room.size.y)
        // Floor-standing footprints only; the TV is wall-mounted.
        let covered = items.filter { $0.category != "television" }.reduce(Float(0)) { $0 + $1.size.x * $1.size.y }
        return RoomFacts.Room(
            label: room.label,
            floorArea: floor,
            openFloorArea: floor - covered,
            grossArea: grossArea(room),
            perimeter: perimeter,
            ceilingHeight: ceiling,
            wallArea: perimeter * ceiling - openingArea,
            doorCount: doors,
            windowCount: windows,
            openingCount: openings,
            objects: items.map { .init(category: $0.category, attributes: [], width: $0.size.x,
                                       depth: $0.size.y, height: $0.height) })
    }

    private static func grossArea(_ room: RoomSpec) -> Float {
        (room.size.x + wall) * (room.size.y + wall)
    }

    // MARK: - Plan

    private static func seg(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> FloorPlan.Segment { .init(start: a, end: b) }

    private static func walls(of r: RoomSpec) -> [FloorPlan.Segment] {
        [seg(r.min, [r.max.x, r.min.y]), seg([r.max.x, r.min.y], r.max),
         seg(r.max, [r.min.x, r.max.y]), seg([r.min.x, r.max.y], r.min)]
    }

    private static func box(_ f: Furniture) -> FloorPlan.Box {
        .init(center: f.center, size: f.size, rotation: f.rotation, label: f.category)
    }

    private static func fixture(_ kind: Fixture.Kind, _ surface: Fixture.Surface, _ at: SIMD2<Float>,
                                length: Float? = nil, axis: SIMD2<Float>? = nil, confidence: Float? = 0.88,
                                source: Fixture.Source = .detected) -> Fixture {
        let y: Float = switch surface { case .floor: 0; case .wall: 0.15; case .ceiling: ceiling }
        return Fixture(kind: kind, surface: surface, position: SIMD3(at.x, y, at.y), planPosition: at, length: length,
                       axis: axis, photoFrame: nil, photoBox: nil, source: source,
                       confidence: source == .manual ? nil : confidence)
    }

    // MARK: - Files

    private static func write(name: String, plan: FloorPlan, facts: RoomFacts, rooms: [RoomSpec],
                              furniture: [Furniture], fixtures: [Fixture],
                              date: Date, root: URL) {
        let scan = Scan(id: UUID(), name: name, kind: .room, createdAt: date, modelFileName: "model.usdz", mode: nil)
        let folder = root.appendingPathComponent(scan.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? plan.write(to: folder.appendingPathComponent(FloorPlan.fileName))
        try? facts.write(to: folder.appendingPathComponent(RoomFacts.fileName))
        FixtureLibrary(fixtures: fixtures, detectedAt: .now, photosChecked: 18)
            .write(to: folder.appendingPathComponent(FixtureLibrary.fileName))
        model(plan: plan, rooms: rooms, furniture: furniture).write(to: folder.appendingPathComponent("model.usdz"),
                                                      options: nil, delegate: nil, progressHandler: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(scan).write(to: folder.appendingPathComponent("scan.json"))
    }

    /// Parametric model like RoomPlan's export: walls, floor and furniture as plain boxes.
    private static func model(plan: FloorPlan, rooms: [RoomSpec], furniture: [Furniture]) -> SCNScene {
        let scene = SCNScene()
        func material(_ white: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(white: white, alpha: 1)
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.8
            return m
        }
        let wallMat = material(0.86), floorMat = material(0.62), itemMat = material(0.74)
        for room in rooms {
            let floor = SCNBox(width: CGFloat(room.size.x), height: 0.02, length: CGFloat(room.size.y),
                               chamferRadius: 0)
            floor.materials = [floorMat]
            let node = SCNNode(geometry: floor)
            node.position = SCNVector3((room.min.x + room.max.x) / 2, -0.01, (room.min.y + room.max.y) / 2)
            scene.rootNode.addChildNode(node)
        }

        for s in plan.walls {
            let length = simd_distance(s.start, s.end)
            let geo = SCNBox(width: CGFloat(length), height: CGFloat(ceiling), length: CGFloat(wall), chamferRadius: 0)
            geo.materials = [wallMat]
            let node = SCNNode(geometry: geo)
            let mid = (s.start + s.end) / 2
            node.position = SCNVector3(mid.x, ceiling / 2, mid.y)
            node.eulerAngles.y = -atan2(s.end.y - s.start.y, s.end.x - s.start.x)
            scene.rootNode.addChildNode(node)
        }

        for f in furniture {
            let geo = SCNBox(width: CGFloat(f.size.x), height: CGFloat(f.height), length: CGFloat(f.size.y),
                             chamferRadius: 0.02)
            geo.materials = [itemMat]
            let node = SCNNode(geometry: geo)
            let lift: Float = f.category == "television" ? 1.0 : 0
            node.position = SCNVector3(f.center.x, lift + f.height / 2, f.center.y)
            node.eulerAngles.y = -f.rotation
            scene.rootNode.addChildNode(node)
        }
        return scene
    }
}
#endif
