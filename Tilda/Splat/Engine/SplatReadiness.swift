import Foundation
import simd

/// A quick look at a scan's photos before training: will the 3D photo come out sharp? Uses only the camera poses in
/// `frames/transforms.json` and the room's floor area, so it takes a fraction of a second and no GPU.
///
/// A splat learns each surface by comparing it across photos taken from different places. It goes soft when there are
/// few photos for the space, when surfaces are seen from only one spot, when everything is shot from one height, or
/// when the ceiling was barely photographed. Thresholds come from the first real room (137 photos for ~50 m², nearly
/// all at chest height, 6 looking up), which trained soft.
enum SplatReadiness {
    enum Grade: Int, Comparable, Sendable {
        case soft, fair, good
        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .good: "Good"
            case .fair: "Fair"
            case .soft: "Likely soft"
            }
        }
    }

    struct Issue: Equatable, Sendable {
        var grade: Grade
        /// What is wrong, in plain words.
        var problem: String
        /// What to do differently next time.
        var fix: String
    }

    struct Report: Equatable, Sendable {
        var grade: Grade
        var issues: [Issue]
        var photoCount: Int
        var photosPerSquareMetre: Float?
    }

    /// Camera summary pulled from the poses. Separate from file reading so it can be checked without files.
    struct Inputs: Equatable {
        var positions: [SIMD3<Float>]
        var forwards: [SIMD3<Float>]
        /// Floor area in m² (rooms only).
        var floorArea: Float?
    }

    static func assess(scanFolder: URL) -> Report? {
        let framesDir = scanFolder.appendingPathComponent("frames", isDirectory: true)
        guard let manifest = FrameRecorder.load(from: framesDir), !manifest.frames.isEmpty else { return nil }
        let positions = manifest.frames.map(\.position)
        let forwards = manifest.frames.map { f -> SIMD3<Float> in
            let c = f.transform.columns.2
            return simd_normalize(-SIMD3(c.x, c.y, c.z))
        }
        var area: Float?
        if let facts = RoomFacts.load(from: scanFolder.appendingPathComponent(RoomFacts.fileName)) {
            let total = facts.totalGrossArea ?? facts.rooms.reduce(0) { $0 + $1.floorArea }
            if total > 1 { area = total }
        }
        return assess(Inputs(positions: positions, forwards: forwards, floorArea: area))
    }

    static func assess(_ input: Inputs) -> Report {
        let n = input.positions.count
        var issues: [Issue] = []
        func grade(_ value: Float, good: Float, fair: Float) -> Grade { value >= good ? .good : value >= fair ? .fair : .soft }

        // 1. Photos for the size of the space.
        var density: Float?
        if let area = input.floorArea {
            let d = Float(n) / area
            density = d
            let g = grade(d, good: 6, fair: 3.5)
            if g < .good {
                issues.append(Issue(grade: g, problem: "\(n) photos is few for a space this size.",
                                    fix: "Set Photo density to Dense in Settings and scan more slowly."))
            }
        } else if n < 120 {
            issues.append(Issue(grade: n < 60 ? .soft : .fair, problem: "Only \(n) photos.",
                                fix: "Set Photo density to Dense in Settings and scan more slowly."))
        }

        // 2. Each view direction seen again from somewhere else (what lets the splat find depth).
        // How far apart two photos must be to add depth scales with the room: surfaces in a bathroom are a metre away,
        // in a big living room several. 0.12 x sqrt(area) gives ~0.27 m for a 5 m² bathroom and caps at 0.5 m.
        let baseline = input.floorArea.map { min(0.5, max(0.2, 0.12 * $0.squareRoot())) } ?? 0.5
        let repeats = medianRepeats(positions: input.positions, forwards: input.forwards, minDistance: baseline)
        let rg = grade(Float(repeats), good: 18, fair: 10)
        if rg < .good {
            issues.append(Issue(grade: rg, problem: "Most surfaces were seen from only a few spots.",
                                fix: "Walk the whole room and look at each wall from several places."))
        }

        // 3. Height variety.
        let heights = input.positions.map(\.y)
        let span = (heights.max() ?? 0) - (heights.min() ?? 0)
        let hg = grade(span, good: 0.8, fair: 0.5)
        if hg < .good {
            issues.append(Issue(grade: hg, problem: "The photos were all taken from about the same height.",
                                fix: "Do one lap holding the phone low and one holding it high."))
        }

        // 4. Ceiling coverage (rooms and spaces: the ceiling is a third of what you see).
        let up = input.forwards.filter { $0.y > sin(20 * Float.pi / 180) }.count
        let upShare = n > 0 ? Float(up) / Float(n) : 0
        let ug = grade(upShare, good: 0.08, fair: 0.04)
        if ug < .good {
            issues.append(Issue(grade: ug, problem: "The ceiling barely appears in the photos.",
                                fix: "Tilt the phone up at the ceiling as you go."))
        }

        // Overall: the worst issue, but one "fair" among goods stays good-ish only if it is the only one.
        let worst = issues.map(\.grade).min() ?? .good
        let softCount = issues.filter { $0.grade == .soft }.count
        let overall: Grade = softCount >= 2 ? .soft : (softCount == 1 || issues.count >= 2) ? min(worst, .fair) : worst
        // Soft issues first: they matter most.
        return Report(grade: overall, issues: issues.sorted { $0.grade < $1.grade }, photoCount: n,
                      photosPerSquareMetre: density)
    }

    /// Median, over photos, of how many other photos look the same way (within 25°) from more than `minDistance` away.
    static func medianRepeats(positions: [SIMD3<Float>], forwards: [SIMD3<Float>], minDistance: Float = 0.5) -> Int {
        let n = positions.count
        guard n > 1 else { return 0 }
        let cosLimit = cos(25 * Float.pi / 180)
        // Thin very long captures so this stays quick (O(n²)).
        let step = max(1, n / 400)
        var counts: [Int] = []
        for i in stride(from: 0, to: n, by: step) {
            var c = 0
            for j in 0..<n where j != i
                && simd_dot(forwards[i], forwards[j]) > cosLimit
                && simd_distance(positions[i], positions[j]) > minDistance { c += 1 }
            counts.append(c)
        }
        counts.sort()
        return counts[counts.count / 2]
    }

    #if DEBUG
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // The first real room: 137 photos, 50 m², one height, few looking up -> soft.
        var pos: [SIMD3<Float>] = [], fwd: [SIMD3<Float>] = []
        for i in 0..<137 {
            let a = Float(i) / 137 * 6 * .pi
            pos.append(SIMD3(3 * cos(Float(i) * 0.05), Float(i % 3) * 0.1, 2.5 * sin(Float(i) * 0.05)))
            let pitch: Float = i % 25 == 0 ? 0.5 : (i % 4 == 0 ? -0.4 : 0)
            fwd.append(simd_normalize(SIMD3(cos(a), pitch, sin(a))))
        }
        let weak = assess(Inputs(positions: pos, forwards: fwd, floorArea: 50))
        expect(weak.grade == .soft, "thin one-height room is soft (got \(weak.grade))")
        expect(weak.issues.contains { $0.problem.contains("same height") }, "flags one height")
        expect(weak.issues.contains { $0.problem.contains("ceiling") }, "flags the ceiling")

        // A thorough capture: 400 photos over three heights, plenty looking up, many repeat views -> good.
        pos = []; fwd = []
        for i in 0..<400 {
            let a = Float(i) / 400 * 16 * .pi
            let h = Float(i % 3) * 0.5
            pos.append(SIMD3(Float(i % 20) * 0.3 - 3, h, Float(i / 20) * 0.25 - 2.5))
            let pitch: Float = i % 6 == 0 ? 0.8 : (i % 5 == 0 ? -0.5 : 0)
            fwd.append(simd_normalize(SIMD3(cos(a), pitch, sin(a))))
        }
        let strong = assess(Inputs(positions: pos, forwards: fwd, floorArea: 50))
        expect(strong.grade == .good, "thorough capture is good (got \(strong.grade), \(strong.issues.map(\.problem)))")
        return failures
    }
    #endif
}
