import Foundation
import FoundationModels
import ImageIO
import Vision

/// Guided-generation output. Only a name and a summary; every number in the summary must come from the facts passed in.
@available(iOS 26.0, *)
@Generable
struct GeneratedScanSummary {
    @Guide(description: "A short title of one to four words, such as \"Living room\" or \"Oak side table\". No dates, no measurements, no quotation marks.")
    var suggestedName: String

    @Guide(description: "Two or three plain sentences describing what was scanned. Mention only measurements that appear in the supplied facts.")
    var summary: String
}

/// Entry point for on-device scan analysis: deterministic facts, Vision tags and text, then an on-device language model
/// (SystemLanguageModel, never Private Cloud Compute) for the name and summary.
enum ScanIntelligence {
    /// True when the on-device Apple Intelligence model can answer right now.
    static var isModelAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// A short, calm reason the model cannot be used, or nil when it is available.
    static var unavailableNote: String? {
        guard #available(iOS 26.0, *) else { return "Names and summaries need iOS 26 or later with Apple Intelligence." }
        return switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "Apple Intelligence isn't available on this iPhone."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to get names and summaries."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again soon."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    static func load(folder: URL) -> ScanInsights? { ScanInsights.load(from: folder) }

    /// Analyses a scan and saves `insights.json`. Returns nil only when nothing at all could be derived.
    static func analyze(scan: Scan, folder: URL, modelURL: URL, focus: ScanFocus = AppSettings.focus) async -> ScanInsights? {
        let measurements = await ScanMeasurements.load(folder: folder, modelURL: modelURL)
        let facts = measurements.facts(kind: scan.kind)
        let vision = await VisionPass.run(folder: folder, kind: scan.kind)

        var name = "", summary = "", usedModel = false
        if #available(iOS 26.0, *), isModelAvailable,
           let generated = await generate(scan: scan, measurements: measurements, facts: facts, vision: vision, focus: focus) {
            name = generated.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”.")))
            summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            usedModel = true
        }

        guard usedModel || !facts.isEmpty || !vision.tags.isEmpty || !vision.text.isEmpty else { return nil }
        let insights = ScanInsights(suggestedName: name, summary: summary, tags: vision.tags, facts: facts,
                                    recognizedText: vision.text, analyzedAt: .now, usedLanguageModel: usedModel,
                                    focus: focus.rawValue)
        insights.write(to: folder)
        return insights
    }

    // MARK: Foundation Models

    @available(iOS 26.0, *)
    private static func generate(scan: Scan, measurements: ScanMeasurements, facts: [ScanInsights.Fact],
                                 vision: VisionPass.Result, focus: ScanFocus) async -> GeneratedScanSummary? {
        var instructions = """
        You name and describe 3D scans made with an iPhone LiDAR scanner. \
        Use only the facts, tags, room labels and text given in the prompt. \
        Never invent, estimate or convert measurements; if you mention a number, copy it exactly from the facts. \
        If something is not listed, do not claim it. Keep the tone plain and factual.
        """
        if !focus.guidance.isEmpty { instructions += "\n" + focus.guidance + " Still copy every number exactly from the facts, and leave out anything that is not listed." }
        var lines = ["Scan type: \(scan.kind.title)"]
        if let rooms = measurements.roomFacts?.rooms.map(\.label), !rooms.isEmpty {
            lines.append("Room labels: " + rooms.joined(separator: ", "))
        }
        if !facts.isEmpty { lines.append("Facts:\n" + facts.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")) }
        if !vision.tags.isEmpty { lines.append("Image tags: " + vision.tags.joined(separator: ", ")) }
        if !vision.text.isEmpty { lines.append("Text seen on the object: " + vision.text.joined(separator: "; ")) }
        lines.append("Give a short name and a two or three sentence summary.")

        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: instructions)
        do {
            let response = try await session.respond(to: lines.joined(separator: "\n"),
                                                     generating: GeneratedScanSummary.self,
                                                     options: GenerationOptions(temperature: 0.4))
            return response.content
        } catch {
            return nil
        }
    }
}

// MARK: - Vision

/// Samples a few photos from the scan and runs on-device image classification and (for objects) text recognition.
enum VisionPass {
    struct Result: Sendable { var tags: [String] = []; var text: [String] = [] }

    private static let generic: Set<String> = ["structure", "material", "others", "other", "indoor", "outdoor",
                                               "object", "wood_processed", "fixture", "container"]

    static func run(folder: URL, kind: ScanKind) async -> Result {
        let (urls, orientation) = samples(folder: folder, kind: kind)
        guard !urls.isEmpty else { return Result() }
        return await Task.detached(priority: .utility) { () -> Result in
            var scores: [String: Float] = [:]
            var seen: [String] = []
            var texts = Set<String>()
            for url in urls {
                if let observations = try? await ClassifyImageRequest().perform(on: url, orientation: orientation) {
                    for o in observations where o.confidence >= 0.15 { scores[o.identifier, default: 0] += o.confidence }
                }
                guard kind == .object else { continue }
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                guard let found = try? await request.perform(on: url, orientation: orientation) else { continue }
                for o in found {
                    guard let c = o.topCandidates(1).first, c.confidence >= 0.5 else { continue }
                    let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard (3...40).contains(s.count), s.filter({ $0.isLetter || $0.isNumber }).count >= 3 else { continue }
                    if texts.insert(s.lowercased()).inserted { seen.append(s) }
                }
            }
            let n = Float(urls.count)
            let tags = scores.filter { !generic.contains($0.key) && $0.value / n >= 0.12 }
                .sorted { $0.value > $1.value }.prefix(8)
                .map { $0.key.replacingOccurrences(of: "_", with: " ") }
            return Result(tags: Array(tags), text: Array(seen.prefix(10)))
        }.value
    }

    /// 3 to 6 evenly spaced photos. Keyframes are landscape sensor frames, so they are rotated upright with `.right`.
    private static func samples(folder: URL, kind: ScanKind) -> ([URL], CGImagePropertyOrientation?) {
        let fm = FileManager.default
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        func files(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var all = files(folder.appendingPathComponent("frames/images", isDirectory: true))
        var orientation: CGImagePropertyOrientation? = .right
        if all.isEmpty {
            all = files(folder.appendingPathComponent("images", isDirectory: true))
            orientation = nil   // Object Capture photos carry their own EXIF orientation
        }
        guard !all.isEmpty else { return ([], nil) }
        let count = min(all.count, kind == .object ? 6 : 5)
        guard count > 1 else { return (all, orientation) }
        let picked = (0..<count).map { all[$0 * (all.count - 1) / (count - 1)] }
        return (picked, orientation)
    }
}
