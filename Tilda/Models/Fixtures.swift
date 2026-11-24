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

        /// Title for use mid-sentence: lowercased, except the acronym ("HVAC vent", "bathroom fan").
        var sentenceTitle: String { self == .hvacVent ? "HVAC vent" : title.lowercased() }
        var sentencePluralTitle: String { self == .hvacVent ? "HVAC vents" : pluralTitle.lowercased() }
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
    /// The user has looked at this one and agrees it is real. Hand-tagged fixtures are always confirmed; detected ones
    /// start unconfirmed. Files saved before this field existed decode as `source == .manual`.
    var confirmed: Bool = false
    /// The user changed its kind, surface, size or position. An edited fixture is also confirmed.
    var edited: Bool = false
}

extension Fixture {
    /// Detected by the model and not yet checked by the user.
    var needsCheck: Bool { source == .detected && !confirmed }
    /// A new detection run must not throw this away.
    var isProtected: Bool { source == .manual || confirmed || edited }
}

extension Fixture.Kind {
    /// Surfaces a fixture of this kind can sit on, most likely first.
    var allowedSurfaces: [Fixture.Surface] {
        switch self {
        case .hvacVent: [.wall, .ceiling, .floor]
        case .bathroomFan: [.ceiling, .wall]
        case .baseboardHeater: [.wall]
        }
    }

    /// Short name for tight spaces (segmented controls, chips).
    var shortTitle: String {
        switch self {
        case .hvacVent: "Vent"
        case .bathroomFan: "Fan"
        case .baseboardHeater: "Heater"
        }
    }
}

extension Fixture {
    private enum CodingKeys: String, CodingKey {
        case id, kind, surface, position, planPosition, length, axis, photoFrame, photoBox, source, confidence,
             confirmed, edited
    }

    // Written by hand (in an extension, so the memberwise init stays) because `confirmed` and `edited` are missing from
    // files saved by version 1.0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        surface = try c.decode(Surface.self, forKey: .surface)
        position = try c.decode(SIMD3<Float>.self, forKey: .position)
        planPosition = try c.decode(SIMD2<Float>.self, forKey: .planPosition)
        length = try c.decodeIfPresent(Float.self, forKey: .length)
        axis = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .axis)
        photoFrame = try c.decodeIfPresent(String.self, forKey: .photoFrame)
        photoBox = try c.decodeIfPresent(NormalizedBox.self, forKey: .photoBox)
        source = try c.decode(Source.self, forKey: .source)
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? (source == .manual)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}

/// Everything saved in `fixtures.json`.
struct FixtureLibrary: Codable, Sendable, Equatable {
    var fixtures: [Fixture] = []
    /// When photo detection last finished. Nil until it has run once (hand-tagged fixtures can exist before that).
    var detectedAt: Date?
    var photosChecked: Int?
    /// Detections the user deleted, so a later run does not bring them back. Optional so files saved before it existed
    /// still decode.
    var dismissed: [Dismissal]?

    /// Where a deleted detection was: a fresh sighting of the same kind this close by is the same false find.
    struct Dismissal: Codable, Sendable, Equatable {
        var kind: Fixture.Kind
        var planPosition: SIMD2<Float>
    }

    static let fileName = "fixtures.json"

    /// The fixtures after a detection run. Fixtures the user has touched are kept. A fresh sighting close to one of
    /// those (same kind, within `radius`) is that fixture, and one close to a dismissal stays deleted. A sighting close
    /// to an unchecked earlier detection takes over its id, so selections and undo in an open editor still match.
    /// Earlier unchecked detections that were not seen again are dropped.
    func merging(detections: [Fixture], radius: Float) -> [Fixture] {
        func near(_ a: Fixture.Kind, _ p: SIMD2<Float>, _ b: Fixture.Kind, _ q: SIMD2<Float>) -> Bool {
            a == b && simd_distance(p, q) < radius
        }
        let kept = fixtures.filter(\.isProtected)
        var unchecked = fixtures.filter { !$0.isProtected }
        var fresh: [Fixture] = []
        for var new in detections {
            if kept.contains(where: { near($0.kind, $0.planPosition, new.kind, new.planPosition) }) { continue }
            if (dismissed ?? []).contains(where: { near($0.kind, $0.planPosition, new.kind, new.planPosition) }) { continue }
            if let i = unchecked.indices.min(by: {
                   simd_distance(unchecked[$0].planPosition, new.planPosition) < simd_distance(unchecked[$1].planPosition, new.planPosition)
               }), near(unchecked[i].kind, unchecked[i].planPosition, new.kind, new.planPosition) {
                new.id = unchecked[i].id
                unchecked.remove(at: i)
            }
            fresh.append(new)
        }
        return kept + fresh
    }

    func count(of kind: Fixture.Kind) -> Int { fixtures.filter { $0.kind == kind }.count }

    /// Detected fixtures the user has not checked yet.
    var uncheckedCount: Int { fixtures.filter(\.needsCheck).count }

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
            var s = "\(n) \(n == 1 ? kind.sentenceTitle : kind.sentencePluralTitle)"
            if kind == .baseboardHeater, heaterLength > 0 { s += " (about \(lengthText(heaterLength)) in total)" }
            return s
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
