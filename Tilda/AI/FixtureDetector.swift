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
    static let imageLongEdge = 1024
    /// Per-photo detections below this are ignored before merging.
    static let minDetectionConfidence: Float = 0.4

    private static let instructions = """
    You look at one photo of the inside of a home, taken while scanning a room. Find only these three fixtures.

    hvacVent: a heating or cooling air register, supply vent or return-air grille. A rectangular or round cover with \
    parallel slats, louvres or a grid of holes, set into a floor, wall or ceiling. Usually metal, plastic or wood, \
    often 4 to 12 inches across, sometimes much larger for a return.

    bathroomFan: a bathroom exhaust fan cover. A flat square or round grille, usually white plastic, set into a \
    ceiling or high on a wall, often 8 to 14 inches across. It may have a small light in the middle.

    baseboardHeater: an electric or hot-water baseboard heater. A long, low, narrow metal housing mounted on a wall \
    just above the floor, typically 2 to 8 feet long, with a slotted or finned front or top and often end caps. \
    It stands several inches out from the wall. Plain wooden or painted baseboard trim is not a heater.

    Do not report: ceiling lights or recessed lights, smoke or carbon monoxide detectors, speakers, sprinkler heads, \
    cameras, power outlets, light switches, thermostats, TVs, cabinets, drawers, radiators that stand freely, \
    windows, doors, curtains, furniture, or plain baseboard trim. If you are not sure, leave it out. \
    If none of the three is visible, return an empty list. Give each box as fractions of the photo width and height \
    with the origin at the top left.
    """

    /// Runs detection over spread-out keyframes. Sequential and cancellable; a failure on one photo skips that photo.
    /// `progress` is called after each photo with (done, total).
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
            guard let image = uprightImage(at: url, orientation: orientation) else {
                failed += 1
                await progress(index + 1, picks.count)
                continue
            }
            do {
                let found = try await detect(in: image)
                checked += 1
                let camera = FixturePlacement.Camera(
                    transform: frame.transform, fx: frame.fl_x, fy: frame.fl_y, cx: frame.cx, cy: frame.cy,
                    width: Float(frame.w), height: Float(frame.h))
                for item in found {
                    guard let sighting = sighting(from: item, frame: frame, orientation: orientation,
                                                  camera: camera, room: room) else { continue }
                    sightings.append(sighting)
                }
            } catch is CancellationError {
                break
            } catch {
                // Refusal, guardrail, context or any other per-photo error: skip this photo, keep going.
                failed += 1
            }
            await progress(index + 1, picks.count)
        }

        return Output(fixtures: FixturePlacement.merge(sightings), photosChecked: checked, photosFailed: failed,
                      cancelled: Task.isCancelled)
    }

    // MARK: Frames

    /// Up to `maxPhotos` keyframes, spread through the room: the photo tour's spots, thinned evenly.
    static func pickFrames(manifest: FrameRecorder.Manifest, framesDir: URL) -> [FrameRecorder.Frame] {
        let spots = TourModel.spots(from: manifest, framesDir: framesDir)
        let byFile = Dictionary(manifest.frames.map { ($0.file_path, $0) }, uniquingKeysWith: { a, _ in a })
        var frames = spots.compactMap { byFile[$0.frameFile] }
        if frames.count > maxPhotos {
            frames = (0..<maxPhotos).map { frames[$0 * (frames.count - 1) / (maxPhotos - 1)] }
        }
        return frames
    }

    /// Downsamples with ImageIO, then turns the photo so world-up is at the top.
    static func uprightImage(at url: URL, orientation: FixturePlacement.Orientation) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageLongEdge,
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

    private static func sighting(from item: GeneratedFixtureSighting, frame: FrameRecorder.Frame,
                                 orientation: FixturePlacement.Orientation, camera: FixturePlacement.Camera,
                                 room: FixturePlacement.Room) -> FixturePlacement.Sighting? {
        let confidence = Float(item.confidence)
        guard confidence >= minDetectionConfidence else { return nil }
        let l = Float(min(max(min(item.left, item.right), 0), 1)), r = Float(min(max(max(item.left, item.right), 0), 1))
        let t = Float(min(max(min(item.top, item.bottom), 0), 1)), b = Float(min(max(max(item.top, item.bottom), 0), 1))
        let w = r - l, h = b - t
        // Reject empty or whole-photo boxes: neither can be a vent or a heater.
        guard w > 0.01, h > 0.01, w * h < 0.6 else { return nil }
        let kind: Fixture.Kind = switch item.kind {
        case .hvacVent: .hvacVent
        case .bathroomFan: .bathroomFan
        case .baseboardHeater: .baseboardHeater
        }
        let surface: Fixture.Surface = switch item.surface {
        case .floor: .floor
        case .wall: .wall
        case .ceiling: .ceiling
        }
        let upright = NormalizedBox(x: l, y: t, width: w, height: h)
        guard let placed = FixturePlacement.place(kind: kind, surface: surface, box: upright, orientation: orientation,
                                                  camera: camera, room: room) else { return nil }
        let sensor = FixturePlacement.sensorBox(uprightX: l, y: t, width: w, height: h, orientation: orientation)
        return FixturePlacement.Sighting(kind: kind, placed: placed, confidence: confidence,
                                         photoFrame: frame.file_path, photoBox: sensor)
    }
}
