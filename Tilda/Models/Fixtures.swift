import Foundation
import simd

/// A rectangle in the sensor image, as fractions of its width and height (origin top-left, landscape sensor
/// orientation, the same way the saved keyframe JPEG is stored).
struct NormalizedBox: Codable, Sendable, Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
}

/// Something RoomPlan cannot classify that matters to a property survey: air vents, bathroom fans, baseboard heaters.
/// Found by the on-device vision model in the scan photos, or tagged by hand. Saved in `fixtures.json`.
struct Fixture: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case hvacVent, bathroomFan, baseboardHeater

        var title: String {
            switch self {
            case .hvacVent: "HVAC vent"
            case .bathroomFan: "Bathroom fan"
            case .baseboardHeater: "Baseboard heater"
            }
        }

        var pluralTitle: String {
            switch self {
            case .hvacVent: "HVAC vents"
            case .bathroomFan: "Bathroom fans"
            case .baseboardHeater: "Baseboard heaters"
            }
        }
    }

    enum Surface: String, Codable, CaseIterable, Sendable {
        case floor, wall, ceiling
        var title: String { rawValue.capitalized }
    }

    enum Source: String, Codable, Sendable { case detected, manual }

    var id = UUID()
    var kind: Kind
    var surface: Surface
    /// World position (ARKit world space, metres).
    var position: SIMD3<Float>
    /// Position on the floor plan (x = world x, y = world z).
    var planPosition: SIMD2<Float>
    /// Heaters: estimated length in metres.
    var length: Float?
    /// Heaters on a wall: unit direction of the wall in plan space, so the unit can be drawn along it.
    var axis: SIMD2<Float>?
    /// `file_path` of the keyframe that shows it (for example `images/frame_00012.jpg`).
    var photoFrame: String?
    /// Where it sits in that keyframe (detected fixtures only).
    var photoBox: NormalizedBox?
    var source: Source
    /// 0...1, detected fixtures only.
    var confidence: Float?
}

/// Everything saved in `fixtures.json`.
struct FixtureLibrary: Codable, Sendable, Equatable {
    var fixtures: [Fixture] = []
    /// When photo detection last finished. Nil until it has run once (hand-tagged fixtures can exist before that).
    var detectedAt: Date?
    var photosChecked: Int?

    static let fileName = "fixtures.json"

    func count(of kind: Fixture.Kind) -> Int { fixtures.filter { $0.kind == kind }.count }

    /// Sum of heater lengths in metres, ignoring heaters whose length is unknown.
    var heaterLength: Float {
        fixtures.filter { $0.kind == .baseboardHeater }.compactMap(\.length).reduce(0, +)
    }

    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> FixtureLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FixtureLibrary.self, from: data)
    }

    static func load(folder: URL) -> FixtureLibrary? { load(from: folder.appendingPathComponent(fileName)) }

    /// One line for the Ask feature and text exports, or nil when nothing was found.
    func summaryLine(lengthText: (Float) -> String) -> String? {
        let parts: [String] = Fixture.Kind.allCases.compactMap { kind in
            let n = count(of: kind)
            guard n > 0 else { return nil }
            var s = "\(n) \(n == 1 ? kind.title.lowercased() : kind.pluralTitle.lowercased())"
            if kind == .baseboardHeater, heaterLength > 0 { s += " (about \(lengthText(heaterLength)) in total)" }
            return s
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
