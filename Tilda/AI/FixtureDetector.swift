import CoreGraphics
import FoundationModels
import ImageIO
import UIKit
import simd

// MARK: - Availability

/// Whether the on-device vision model can look for fixtures right now. On-device only: this never touches
/// PrivateCloudComputeLanguageModel, so no photo leaves the phone.
enum FixtureDetectionSupport {
    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    static var status: Status {
        guard #available(iOS 27.0, *) else {
            return .unavailable("Finding fixtures from photos needs iOS 27 and Apple Intelligence.")
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision)
                ? .available
                : .unavailable("This iPhone's Apple Intelligence model can't read photos.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("Apple Intelligence isn't available on this iPhone.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to find fixtures from photos.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready. Try again soon.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    static var isAvailable: Bool { status == .available }
}

// MARK: - Guided generation

@Generable
enum GeneratedFixtureKind {
    case hvacVent
    case bathroomFan
    case baseboardHeater
}

@Generable
enum GeneratedFixtureSurface {
    case floor
    case wall
    case ceiling
}

@Generable
struct GeneratedFixtureSighting {
    @Guide(description: "Which of the three fixture types this is.")
    var kind: GeneratedFixtureKind

    @Guide(description: "The surface it is mounted on or set into: floor, wall or ceiling.")
    var surface: GeneratedFixtureSurface

    @Guide(description: "Left edge of the fixture as a fraction of the photo width, 0 at the left edge and 1 at the right.", .range(0...1))
    var left: Double
    @Guide(description: "Top edge of the fixture as a fraction of the photo height, 0 at the top and 1 at the bottom.", .range(0...1))
    var top: Double
    @Guide(description: "Right edge of the fixture as a fraction of the photo width.", .range(0...1))
    var right: Double
    @Guide(description: "Bottom edge of the fixture as a fraction of the photo height.", .range(0...1))
    var bottom: Double

    @Guide(description: "How sure you are, from 0 to 1. Use 0.9 or more only when it is clearly one of the three types.", .range(0...1))
    var confidence: Double
}

@Generable
struct GeneratedFixtureScan {
    @Guide(description: "Every vent, bathroom fan or baseboard heater clearly visible in the photo. Empty when there are none.",
           .maximumCount(6))
    var items: [GeneratedFixtureSighting]
}

/// A baseboard heater seen by the heater-only pass.
@Generable
struct GeneratedHeaterSighting {
    @Guide(description: "Left edge of the heater as a fraction of the photo width, 0 at the left edge and 1 at the right.", .range(0...1))
    var left: Double
    @Guide(description: "Top edge of the heater as a fraction of the photo height, 0 at the top and 1 at the bottom.", .range(0...1))
    var top: Double
    @Guide(description: "Right edge of the heater as a fraction of the photo width.", .range(0...1))
    var right: Double
    @Guide(description: "Bottom edge of the heater as a fraction of the photo height.", .range(0...1))
    var bottom: Double
    @Guide(description: "How sure you are that it is a baseboard heater and not trim, from 0 to 1.", .range(0...1))
    var confidence: Double
}

@Generable
struct GeneratedHeaterScan {
    @Guide(description: "Every baseboard heater clearly visible in the photo. Empty when there are none.", .maximumCount(4))
    var items: [GeneratedHeaterSighting]
}

/// The close-up second look at one heater candidate. The clues come first and the verdict last, so the verdict
/// follows from what was seen.
@Generable
struct GeneratedHeaterVerdict {
    @Guide(description: "True when the front or top has fins, slots or louvres (a grille of parallel openings).")
    var hasFinsOrSlots: Bool
    @Guide(description: "True when the ends are closed off with metal end caps.")
    var hasEndCaps: Bool
    @Guide(description: "True when it is a housing that stands several centimetres out from the wall, deeper than normal trim.")
    var standsOutFromWall: Bool
    @Guide(description: "True when it is only a flat strip of wooden or painted baseboard trim or moulding.")
    var isPlainTrimOrMoulding: Bool
    @Guide(description: "True when it is a radiator or heater that stands on its own legs or on the floor away from the wall.")
    var isFreestandingRadiator: Bool
    @Guide(description: "True only when this is a wall-mounted baseboard heater.")
    var isBaseboardHeater: Bool
}

// MARK: - Detector

/// Looks through a Room scan's keyframes with the on-device vision model and places what it finds in the room.
@available(iOS 27.0, *)
enum FixtureDetector {
    struct Output: Sendable {
        var fixtures: [Fixture]
        var photosChecked: Int
        var photosFailed: Int
        var cancelled: Bool
    }

    static let maxPhotos = 24
    /// Extra frames that look down at the base of the walls, where heaters are easier to see.
    static let maxHeaterPhotos = 8
    /// The heater pass looks at this bottom share of the upright photo.
    static let heaterCropFraction: Float = 0.55
    static let imageLongEdge = 1024
    /// Per-photo detections below this are ignored before merging.
    static let minDetectionConfidence: Float = 0.4

    private static let heaterInstructions = """
    You look at the lower part of one photo of the inside of a home: the bottom of the walls and the floor. Find \
    only baseboard heaters, electric or hot-water. A baseboard heater is a long, low metal housing mounted on a wall \
    just above the floor, usually 2 to 8 feet long. What tells it from trim: the housing is several centimetres deep \
    and stands out from the wall, the top or front has fins, slots or a row of louvres, the ends have end caps, and \
    there is often a thermostat knob on one end. It is usually painted white or beige metal, and is common under \
    windows. Plain wooden or painted baseboard trim is a flat strip with no slots and no depth: it is not a heater. \
    Also not heaters: free-standing radiators, vents and floor registers, cabinets, drawers, furniture legs, \
    power outlets and door frames. If you are not sure, leave it out. If there is no baseboard heater, return an \
    empty list. Give each box as fractions of the photo width and height with the origin at the top left, and make \
    the box fit the heater's full visible length.
    """

    private static let verifyInstructions = """
    You are shown a close-up of one thing that might be a baseboard heater on a wall. Judge only what you can see. \
    A real baseboard heater is a metal housing several centimetres deep that stands out from the wall, with fins, \
    slots or louvres on the top or front and usually end caps. Plain baseboard trim or moulding is a flat wooden or \
    painted strip with no slots and little depth. A free-standing radiator stands on legs or on the floor. \
    Answer each question honestly; say no when you cannot tell.
    """

    private static let instructions = """
    You look at one photo of the inside of a home, taken while scanning a room. Find only these three fixtures.

    hvacVent: a heating or cooling air register, supply vent or return-air grille. A rectangular or round cover with \
    parallel slats, louvres or a grid of holes, set into a floor, wall or ceiling. Usually metal, plastic or wood, \
    often 4 to 12 inches across, sometimes much larger for a return.

    bathroomFan: a bathroom exhaust fan cover. A flat square or round grille, usually white plastic, set into a \
    ceiling or high on a wall, often 8 to 14 inches across. It may have a small light in the middle.

    baseboardHeater: an electric or hot-water baseboard heater. A long, low metal housing mounted on a wall just \
    above the floor, typically 2 to 8 feet long. What tells it from trim: the housing is several centimetres deep and \
    stands out from the wall, the top or front has fins, slots or a row of louvres, the ends have end caps, and there \
    is often a thermostat knob on one end. Usually painted white or beige metal. Under a window is common. \
    Plain wooden or painted baseboard trim is a flat strip with no slots and no depth: it is not a heater.

    Do not report: ceiling lights or recessed lights, smoke or carbon monoxide detectors, speakers, sprinkler heads, \
    cameras, power outlets, light switches, thermostats, TVs, cabinets, drawers, radiators that stand freely, \
    windows, doors, curtains, furniture, or plain baseboard trim. If you are not sure, leave it out. \
    If none of the three is visible, return an empty list. Give each box as fractions of the photo width and height \
    with the origin at the top left.
    """

    /// Runs detection over spread-out keyframes. Sequential and cancellable; a failure on one model call skips that
    /// call only. `progress` is called after each photo with (done, total).
    static func run(framesDir: URL, plan: FloorPlan?, facts: RoomFacts?,
                    progress: @escaping @Sendable (Int, Int) async -> Void) async -> Output {
        guard let manifest = FrameRecorder.load(from: framesDir), let plan else {
            return Output(fixtures: [], photosChecked: 0, photosFailed: 0, cancelled: false)
        }
        let ceilingHeight = (facts?.averageCeiling).flatMap { $0 > 1.5 ? $0 : nil } ?? FixturePlacement.defaultCeilingHeight
        let room = FixturePlacement.Room(floorY: plan.floorY, ceilingY: plan.floorY + ceilingHeight, walls: plan.walls)
        let picks = pickFrames(manifest: manifest, framesDir: framesDir)

        var sightings: [FixturePlacement.Sighting] = []
        var failed = 0
        var checked = 0
        await progress(0, picks.count)

        for (index, frame) in picks.enumerated() {
            if Task.isCancelled { break }
            let orientation = FixturePlacement.orientation(for: frame.transform)
            let url = framesDir.appendingPathComponent(frame.file_path)
            guard let image = uprightImage(at: url, orientation: orientation, longEdge: nil) else {
                failed += 1
                await progress(index + 1, picks.count)
                continue
            }
            let camera = FixturePlacement.Camera(
                transform: frame.transform, fx: frame.fl_x, fy: frame.fl_y, cx: frame.cx, cy: frame.cy,
                width: Float(frame.w), height: Float(frame.h))
            do {
                let result = try await process(image: image, frame: frame, orientation: orientation, camera: camera, room: room)
                sightings += result.sightings
                if result.anyCallWorked { checked += 1 } else { failed += 1 }
            } catch {
                break      // cancelled
            }
            await progress(index + 1, picks.count)
        }

        return Output(fixtures: FixturePlacement.merge(sightings), photosChecked: checked, photosFailed: failed,
                      cancelled: Task.isCancelled)
    }

    private struct FrameResult {
        var sightings: [FixturePlacement.Sighting] = []
        var anyCallWorked = false
    }

    /// A heater the model reported, as a box in the full upright photo (fractions).
    private struct HeaterCandidate {
        var box: NormalizedBox
        var confidence: Float
    }

    /// Everything for one photo: the full-image call (vents, fans, heaters), the heater-only call on the lower part,
    /// then placement and a close-up check of each heater. Only throws `CancellationError`.
    private static func process(image: CGImage, frame: FrameRecorder.Frame, orientation: FixturePlacement.Orientation,
                                camera: FixturePlacement.Camera, room: FixturePlacement.Room) async throws -> FrameResult {
        var result = FrameResult()
        var fullImageHeaters: [HeaterCandidate] = []

        // 1. The whole photo, downsampled.
        if let found = try await attempt({ try await detect(in: scaled(image, longEdge: imageLongEdge)) }) {
            result.anyCallWorked = true
            for item in found {
                if item.kind == .baseboardHeater {
                    if let box = normalizedBox(left: item.left, top: item.top, right: item.right, bottom: item.bottom) {
                        fullImageHeaters.append(HeaterCandidate(box: box, confidence: Float(item.confidence)))
                    }
                } else if let s = sighting(from: item, frame: frame, orientation: orientation, camera: camera, room: room) {
                    result.sightings.append(s)
                }
            }
        }
        try Task.checkCancellation()

        // 2. Heaters only, on the bottom of the photo cropped from the full-resolution image, so the thin strip a heater
        // makes carries more pixels than it does in the downsample.
        var candidates: [HeaterCandidate] = []
        let cropTop = CGFloat(image.height) * CGFloat(1 - heaterCropFraction)
        let cropRect = CGRect(x: 0, y: cropTop.rounded(), width: CGFloat(image.width),
                              height: CGFloat(image.height) - cropTop.rounded())
        if let lower = image.cropping(to: cropRect),
           let found = try await attempt({ try await detectHeaters(in: scaled(lower, longEdge: imageLongEdge)) }) {
            result.anyCallWorked = true
            for item in found {
                guard let b = normalizedBox(left: item.left, top: item.top, right: item.right, bottom: item.bottom) else { continue }
                // Back to fractions of the whole upright photo.
                let full = NormalizedBox(x: b.x, y: (1 - heaterCropFraction) + b.y * heaterCropFraction,
                                         width: b.width, height: b.height * heaterCropFraction)
                candidates.append(HeaterCandidate(box: full, confidence: Float(item.confidence)))
            }
        }
        // A full-photo heater the lower pass also found is the same heater; the lower pass's box is the better one.
        candidates += fullImageHeaters.filter { h in !candidates.contains { FixturePlacement.boxesOverlap($0.box, h.box) } }
        try Task.checkCancellation()

        // 3. Place each heater on its wall, then take a close look to rule out trim.
        for candidate in candidates where candidate.confidence >= minDetectionConfidence {
            let b = candidate.box
            guard let placed = FixturePlacement.placeHeater(box: b, orientation: orientation, camera: camera, room: room) else { continue }
            let crop = FixturePlacement.cropRect(box: b, imageWidth: Float(image.width), imageHeight: Float(image.height))
            guard let closeUp = image.cropping(to: crop),
                  let verdict = try await attempt({ try await verify(scaled(closeUp, longEdge: imageLongEdge)) }) else { continue }
            try Task.checkCancellation()
            guard FixturePlacement.heaterVerdictAccepted(
                isHeater: verdict.isBaseboardHeater, plainTrim: verdict.isPlainTrimOrMoulding,
                freestanding: verdict.isFreestandingRadiator, fins: verdict.hasFinsOrSlots,
                endCaps: verdict.hasEndCaps, standsOut: verdict.standsOutFromWall) else { continue }
            let sensor = FixturePlacement.sensorBox(uprightX: b.x, y: b.y, width: b.width, height: b.height, orientation: orientation)
            result.sightings.append(FixturePlacement.Sighting(
                kind: .baseboardHeater, placed: placed, confidence: candidate.confidence,
                photoFrame: frame.file_path, photoBox: sensor, verified: true))
        }
        return result
    }

    /// Runs one model call. A failure (refusal, guardrail, context, anything) gives nil so the caller skips just that
    /// call; cancellation is passed on.
    private static func attempt<T>(_ body: () async throws -> T) async throws -> T? {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// An upright-photo box from the model's edges, or nil when it is empty or fills the photo (neither can be a fixture).
    private static func normalizedBox(left: Double, top: Double, right: Double, bottom: Double) -> NormalizedBox? {
        let l = Float(min(max(min(left, right), 0), 1)), r = Float(min(max(max(left, right), 0), 1))
        let t = Float(min(max(min(top, bottom), 0), 1)), b = Float(min(max(max(top, bottom), 0), 1))
        let w = r - l, h = b - t
        guard w > 0.01, h > 0.01, w * h < 0.6 else { return nil }
        return NormalizedBox(x: l, y: t, width: w, height: h)
    }

    // MARK: Frames

    /// Up to `maxPhotos` keyframes, spread through the room (the photo tour's spots, thinned evenly), plus up to
    /// `maxHeaterPhotos` that look down at the base of the walls and are not near-duplicates of those.
    static func pickFrames(manifest: FrameRecorder.Manifest, framesDir: URL) -> [FrameRecorder.Frame] {
        let spots = TourModel.spots(from: manifest, framesDir: framesDir)
        let byFile = Dictionary(manifest.frames.map { ($0.file_path, $0) }, uniquingKeysWith: { a, _ in a })
        var frames = spots.compactMap { byFile[$0.frameFile] }
        if frames.count > maxPhotos {
            frames = (0..<maxPhotos).map { frames[$0 * (frames.count - 1) / (maxPhotos - 1)] }
        }
        let picked = Set(frames.map(\.file_path))
        let downward = manifest.frames.filter { !picked.contains($0.file_path) && FixturePlacement.looksDown($0.transform) }
        let extra = FixturePlacement.spreadPicks(candidates: downward.map { FixturePlacement.pose(of: $0.transform) },
                                                 existing: frames.map { FixturePlacement.pose(of: $0.transform) },
                                                 limit: maxHeaterPhotos)
        return frames + extra.map { downward[$0] }
    }

    /// Reads the photo with ImageIO, then turns it so world-up is at the top. `longEdge` downsamples to that many
    /// pixels; nil keeps full resolution (for crops).
    static func uprightImage(at url: URL, orientation: FixturePlacement.Orientation, longEdge: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var maxPixels = longEdge ?? 0
        if longEdge == nil {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            maxPixels = max((props?[kCGImagePropertyPixelWidth] as? Int) ?? 4096, (props?[kCGImagePropertyPixelHeight] as? Int) ?? 4096)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let uiOrientation: UIImage.Orientation = switch orientation {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
        let image = UIImage(cgImage: cg, scale: 1, orientation: uiOrientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }

    /// The image shrunk so its long edge is at most `longEdge` pixels (never enlarged).
    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > longEdge else { return image }
        let k = CGFloat(longEdge) / CGFloat(long)
        let size = CGSize(width: (CGFloat(image.width) * k).rounded(), height: (CGFloat(image.height) * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage ?? image
    }

    // MARK: Model

    private static func detect(in image: CGImage) async throws -> [GeneratedFixtureSighting] {
        // A fresh session per photo keeps every call independent and the context small.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let prompt = Prompt {
            "Find any HVAC vents, bathroom fans or baseboard heaters in this photo."
            Attachment(image)
        }
        let response = try await session.respond(to: prompt, generating: GeneratedFixtureScan.self,
                                                 options: GenerationOptions(temperature: 0.1))
        return response.content.items
    }

    /// The heater-only call, on the lower part of a photo.
    private static func detectHeaters(in image: CGImage) async throws -> [GeneratedHeaterSighting] {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: heaterInstructions)
        let prompt = Prompt {
            "Find any baseboard heaters in this photo of the bottom of the walls and the floor."
            Attachment(image)
        }
        let response = try await session.respond(to: prompt, generating: GeneratedHeaterScan.self,
                                                 options: GenerationOptions(temperature: 0.1))
        return response.content.items
    }

    /// The close-up check of one heater candidate: one cheap call in a fresh session.
    private static func verify(_ image: CGImage) async throws -> GeneratedHeaterVerdict {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: verifyInstructions)
        let prompt = Prompt {
            "Is the long low object in this close-up a real baseboard heater?"
            Attachment(image)
        }
        let response = try await session.respond(to: prompt, generating: GeneratedHeaterVerdict.self,
                                                 options: GenerationOptions(temperature: 0.1))
        return response.content
    }

    /// A vent or fan sighting placed in the room. Heaters take the floor-anchored path in `process` instead.
    private static func sighting(from item: GeneratedFixtureSighting, frame: FrameRecorder.Frame,
                                 orientation: FixturePlacement.Orientation, camera: FixturePlacement.Camera,
                                 room: FixturePlacement.Room) -> FixturePlacement.Sighting? {
        let confidence = Float(item.confidence)
        guard confidence >= minDetectionConfidence else { return nil }
        // Reject empty or whole-photo boxes: neither can be a vent or a fan.
        guard let upright = normalizedBox(left: item.left, top: item.top, right: item.right, bottom: item.bottom) else { return nil }
        let kind: Fixture.Kind = switch item.kind {
        case .hvacVent: .hvacVent
        case .bathroomFan: .bathroomFan
        case .baseboardHeater: .baseboardHeater
        }
        guard kind != .baseboardHeater else { return nil }
        let surface: Fixture.Surface = switch item.surface {
        case .floor: .floor
        case .wall: .wall
        case .ceiling: .ceiling
        }
        guard let placed = FixturePlacement.place(kind: kind, surface: surface, box: upright, orientation: orientation,
                                                  camera: camera, room: room) else { return nil }
        let sensor = FixturePlacement.sensorBox(uprightX: upright.x, y: upright.y, width: upright.width, height: upright.height,
                                                orientation: orientation)
        return FixturePlacement.Sighting(kind: kind, placed: placed, confidence: confidence,
                                         photoFrame: frame.file_path, photoBox: sensor)
    }
}
