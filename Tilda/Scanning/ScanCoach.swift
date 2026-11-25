import Foundation
import simd

/// One short reminder the scanning assistant can show.
enum CoachTip: String, CaseIterable, Sendable {
    case slowDown, tiltUp, tiltDown, lower, higher, otherSide

    var text: String {
        switch self {
        case .slowDown: "Slow down a little"
        case .tiltUp: "Tilt up to capture the ceiling"
        case .tiltDown: "Tilt down at the floor and wall bases"
        case .lower: "Hold the phone lower for a bit"
        case .higher: "Hold the phone higher for a bit"
        case .otherSide: "Look back from the other side"
        }
    }

    var symbol: String {
        switch self {
        case .slowDown: "tortoise"
        case .tiltUp: "arrow.up.to.line"
        case .tiltDown: "arrow.down.to.line"
        case .lower: "arrow.down.circle"
        case .higher: "arrow.up.circle"
        case .otherSide: "arrow.uturn.left"
        }
    }

    /// Lower number wins when several tips apply.
    fileprivate var priority: Int {
        switch self {
        case .slowDown: 0
        case .tiltUp: 1
        case .tiltDown: 2
        case .lower, .higher: 3
        case .otherSide: 4
        }
    }
}

/// Live coverage numbers for the scan so far. Pure value type, no ARKit, O(1) per update.
///
/// Targets mirror `SplatReadiness`: ceiling share 8%, height span 0.8 m, 6 photos per m², and each view direction
/// seen again from another spot (a baseline that grows with the space walked, 0.2 to 0.5 m).
struct ScanCoachStats {
    static let yawBins = 8
    /// Pitch beyond which a photo counts as looking up or down.
    static let tiltLimit: Float = 20 * .pi / 180

    private(set) var startTime: Double?
    private(set) var lastTime: Double = 0
    private(set) var startY: Float = 0
    private(set) var minY: Float = 0
    private(set) var maxY: Float = 0
    private var minX: Float = 0, maxX: Float = 0, minZ: Float = 0, maxZ: Float = 0
    private(set) var photos = 0
    private(set) var up = 0
    private(set) var down = 0
    /// Smoothed camera turning speed in degrees per second.
    private(set) var turnRate: Float = 0
    /// Blur-skipped frames, decayed with a ~4 s time constant: roughly "how many just now".
    private(set) var blurScore: Float = 0

    private var lastForward: SIMD3<Float>?
    private var lastKept = 0
    private var lastBlur = 0

    private struct Bin {
        var count = 0
        var first = SIMD2<Float>(0, 0)
        var farDist: Float = 0
    }
    private var bins = [Bin](repeating: Bin(), count: ScanCoachStats.yawBins)

    var elapsed: Double { (startTime.map { lastTime - $0 }) ?? 0 }
    var heightSpan: Float { maxY - minY }
    /// Has the phone been held clearly below / above where the scan started?
    var coveredLow: Bool { startY - minY >= 0.3 }
    var upShare: Float { photos > 0 ? Float(up) / Float(photos) : 0 }
    var downShare: Float { photos > 0 ? Float(down) / Float(photos) : 0 }

    /// Floor area of the space walked so far, padded 1 m each side for the walls (never under 6 m²).
    var spaceArea: Float { max(6, (maxX - minX + 2) * (maxZ - minZ + 2)) }
    var photosPerSquareMetre: Float { Float(photos) / spaceArea }
    /// How far apart two photos must be to count as different spots.
    var baseline: Float { min(0.5, max(0.2, 0.12 * spaceArea.squareRoot())) }
    /// View directions with a couple of photos.
    var seenDirections: Int { bins.filter { $0.count >= 2 }.count }
    /// Seen directions that were photographed from only one spot so far.
    var singleSpotDirections: Int { bins.filter { $0.count >= 2 && $0.farDist < baseline }.count }

    mutating func record(position p: SIMD3<Float>, forward f: SIMD3<Float>, time: Double,
                         keptTotal: Int, blurSkippedTotal: Int) {
        let dt = Float(time - lastTime)
        if startTime == nil {
            startTime = time
            startY = p.y; minY = p.y; maxY = p.y
            minX = p.x; maxX = p.x; minZ = p.z; maxZ = p.z
            lastKept = keptTotal; lastBlur = blurSkippedTotal
        } else {
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.z); maxZ = max(maxZ, p.z)
            if let last = lastForward, dt > 0.02, dt < 1.5 {
                let angle = acos(min(max(simd_dot(last, f), -1), 1)) * 180 / .pi
                turnRate += 0.4 * (angle / dt - turnRate)
            }
            blurScore *= exp(-dt / 4)
        }
        lastTime = time
        lastForward = f

        blurScore += Float(max(0, blurSkippedTotal - lastBlur))
        lastBlur = blurSkippedTotal

        // Photos kept since the last update were taken moments ago, so they share this pose.
        let newPhotos = min(4, max(0, keptTotal - lastKept))
        lastKept = keptTotal
        photos = keptTotal
        for _ in 0..<newPhotos { notePhoto(position: p, forward: f) }
    }

    private mutating func notePhoto(position p: SIMD3<Float>, forward f: SIMD3<Float>) {
        if f.y > sin(Self.tiltLimit) { up += 1 }
        if f.y < -sin(Self.tiltLimit) { down += 1 }
        // Directions only mean something for photos that look roughly sideways.
        guard abs(f.y) < 0.85 else { return }
        var yaw = atan2(f.x, f.z)
        if yaw < 0 { yaw += 2 * .pi }
        let i = min(Self.yawBins - 1, Int(yaw / (2 * .pi) * Float(Self.yawBins)))
        let spot = SIMD2(p.x, p.z)
        if bins[i].count == 0 { bins[i].first = spot }
        bins[i].count += 1
        bins[i].farDist = max(bins[i].farDist, simd_distance(spot, bins[i].first))
    }
}

/// Picks at most one tip at a time from the live stats, without flicker or nagging.
///
/// - Nothing in the first 5 s.
/// - Each tip turns on at one threshold and off at a looser one (hysteresis).
/// - A tip stays at least 4 s, at most 12 s; once gone it cannot return for 40 s (60 s if it was ignored).
/// - A higher-priority tip can replace the current one only after the 4 s minimum.
struct ScanCoach {
    struct State: Equatable {
        var tip: CoachTip?
        /// All targets met: shown as a quiet "Good coverage" state, not a tip.
        var goodCoverage = false
    }

    static let quietStart: Double = 5
    static let minDisplay: Double = 4
    static let maxDisplay: Double = 12
    static let cooldown: Double = 40
    static let ignoredCooldown: Double = 60
    static let gapBetweenTips: Double = 1.5

    private(set) var stats = ScanCoachStats()
    private(set) var state = State()

    private var slowActive = false, upActive = false, downActive = false, otherSideActive = false
    private var heightTip: CoachTip?
    private var tipSince: Double = 0
    private var lastHidden: Double = -.infinity
    private var cooldownUntil: [CoachTip: Double] = [:]

    mutating func ingest(position: SIMD3<Float>, forward: SIMD3<Float>, time: Double,
                         keptTotal: Int, blurSkippedTotal: Int) -> State {
        stats.record(position: position, forward: forward, time: time,
                     keptTotal: keptTotal, blurSkippedTotal: blurSkippedTotal)
        let t = stats.elapsed
        let active = refreshConditions()

        if let current = state.tip {
            let shown = t - tipSince
            if shown >= Self.maxDisplay {
                hide(current, at: t, ignored: true)
            } else if shown >= Self.minDisplay {
                if !active.contains(current) {
                    hide(current, at: t, ignored: false)
                } else if let better = best(active, at: t), better.priority < current.priority {
                    hide(current, at: t, ignored: false)
                    state.tip = better
                    tipSince = t
                }
            }
        }
        if state.tip == nil, t >= Self.quietStart, t - lastHidden >= Self.gapBetweenTips,
           let next = best(active, at: t) {
            state.tip = next
            tipSince = t
        }
        state.goodCoverage = updateGood(anyTip: !active.isEmpty)
        return state
    }

    private mutating func hide(_ tip: CoachTip, at t: Double, ignored: Bool) {
        state.tip = nil
        lastHidden = t
        cooldownUntil[tip] = t + (ignored ? Self.ignoredCooldown : Self.cooldown)
    }

    private func best(_ active: Set<CoachTip>, at t: Double) -> CoachTip? {
        active.filter { (cooldownUntil[$0] ?? 0) <= t }.min { $0.priority < $1.priority }
    }

    /// Updates each hysteresis flag and returns the tips whose condition holds right now.
    private mutating func refreshConditions() -> Set<CoachTip> {
        let s = stats
        slowActive = slowActive ? (s.blurScore >= 1 || s.turnRate >= 45) : (s.blurScore >= 3 || s.turnRate >= 75)

        let enough = s.photos >= 30
        upActive = enough && (upActive ? s.upShare < 0.09 : s.upShare < 0.06)
        downActive = enough && (downActive ? s.downShare < 0.08 : s.downShare < 0.05)

        // Height: wait until the user has settled in, then ask for the side not yet covered (lower first).
        if s.elapsed >= 20, s.photos >= 25, s.heightSpan < (heightTip == nil ? 0.8 : 0.9) {
            heightTip = s.coveredLow ? .higher : .lower
        } else {
            heightTip = nil
        }

        let weak = s.singleSpotDirections
        // The first pass round a room sees every direction from one spot, so only judge once there is a real walk behind it.
        otherSideActive = s.photos >= 60 && s.elapsed >= 30 && s.seenDirections >= 4 && (otherSideActive ? weak >= 2 : weak >= 3)

        var active = Set<CoachTip>()
        if slowActive { active.insert(.slowDown) }
        if upActive { active.insert(.tiltUp) }
        if downActive { active.insert(.tiltDown) }
        if let heightTip { active.insert(heightTip) }
        if otherSideActive { active.insert(.otherSide) }
        return active
    }

    private func updateGood(anyTip: Bool) -> Bool {
        let s = stats
        guard !anyTip, s.photos >= 60 else { return false }
        if state.goodCoverage {
            return s.upShare >= 0.06 && s.downShare >= 0.04 && s.heightSpan >= 0.7
                && s.singleSpotDirections <= 2 && s.photosPerSquareMetre >= 5
        }
        return s.upShare >= 0.08 && s.downShare >= 0.06 && s.heightSpan >= 0.8 && s.seenDirections >= 6
            && s.singleSpotDirections <= 1 && s.photosPerSquareMetre >= 6
    }

    #if DEBUG
    // MARK: Self-check

    /// Drives a coach through simulated walks at 4 Hz. `pose` returns position and forward for step i.
    private static func simulate(seconds: Double, photosPerSecond: Double = 2.5, blurPerSecond: Double = 0,
                                 pose: (Int) -> (SIMD3<Float>, SIMD3<Float>),
                                 coach: inout ScanCoach, log: ((Double, State) -> Void)? = nil) {
        let steps = Int(seconds * 4)
        for i in 0..<steps {
            let time = 1000 + Double(i) / 4
            let (p, f) = pose(i)
            let state = coach.ingest(position: p, forward: simd_normalize(f), time: time,
                                     keptTotal: Int(Double(i) / 4 * photosPerSecond),
                                     blurSkippedTotal: Int(Double(i) / 4 * blurPerSecond))
            log?(Double(i) / 4, state)
        }
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        /// Walks a loop, turning slowly. `pitchOf` and `heightOf` shape what the walk looks like.
        func loop(_ i: Int, pitch: Float, height: Float, radius: Float = 2) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = Float(i) * 0.02
            let yaw = Float(i) * 0.06
            return (SIMD3(radius * cos(a), height, radius * sin(a)),
                    SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)))
        }

        // 1. Chest height only, never up or down: asks for the ceiling first; once that is done, lower, then higher.
        var coach = ScanCoach()
        var seen: [CoachTip] = []
        simulate(seconds: 90, pose: { loop($0, pitch: 0, height: 0) }, coach: &coach) { _, s in
            if let tip = s.tip, seen.last != tip { seen.append(tip) }
        }
        expect(seen.first == .tiltUp, "chest-height walk asks to tilt up first (got \(seen))")
        expect(seen.contains(.lower), "chest-height walk asks to hold lower (got \(seen))")
        expect(!seen.contains(.higher) || seen.firstIndex(of: .lower)! < seen.firstIndex(of: .higher)!,
               "lower comes before higher (got \(seen))")

        // 2. Looking up and down fine, one height: asks lower, then higher once lowered.
        coach = ScanCoach()
        seen = []
        simulate(seconds: 120, pose: { i in
            let pitch = 0.55 * sin(Float(i) * 0.17)
            // Spend the second half of the walk 40 cm lower.
            return loop(i, pitch: pitch, height: i > 240 ? -0.4 : 0)
        }, coach: &coach) { _, s in if let tip = s.tip, seen.last != tip { seen.append(tip) } }
        expect(seen.first == .lower, "one-height walk asks lower first (got \(seen))")
        expect(seen.contains(.higher), "after lowering, asks higher (got \(seen))")

        // 3. Fast turning with blurred frames asks to slow down.
        coach = ScanCoach()
        var slowShown = false
        simulate(seconds: 30, blurPerSecond: 2, pose: { i in
            let yaw = Float(i) * 0.5   // 0.5 rad per 0.25 s = 115 deg/s
            return (SIMD3(Float(i) * 0.005, 0, 0), SIMD3(sin(yaw), 0, cos(yaw)))
        }, coach: &coach) { _, s in if s.tip == .slowDown { slowShown = true } }
        expect(slowShown, "fast turning asks to slow down")

        // 4. A thorough walk (three heights, up and down, every direction from many spots) ends in good coverage.
        coach = ScanCoach()
        var goodSeen = false
        var tipsAfterGood = false
        simulate(seconds: 240, photosPerSecond: 3, pose: { i in
            let lap = i / 160                        // 40 s laps
            let height: Float = [0, -0.45, 0.45][lap % 3]
            let a = Float(i) * 0.04
            let yaw = Float(i) * 0.05                // a slow spin while walking, so every direction recurs
            let pitch = 0.6 * sin(Float(i) * 0.21)
            let r: Float = 1.2 + Float(i % 3)
            return (SIMD3(r * cos(a) * 1.5, height, r * sin(a) * 1.2),
                    SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)))
        }, coach: &coach) { _, s in
            if s.goodCoverage { goodSeen = true }
            if goodSeen && s.tip != nil { tipsAfterGood = true }
        }
        expect(goodSeen, "thorough walk reaches good coverage (stats: up \(coach.stats.upShare), down \(coach.stats.downShare), span \(coach.stats.heightSpan), seen \(coach.stats.seenDirections), single \(coach.stats.singleSpotDirections), density \(coach.stats.photosPerSquareMetre))")
        _ = tipsAfterGood

        // 5. Nothing in the first 5 s, never two tips, min display and cooldown respected.
        coach = ScanCoach()
        var firstTipAt: Double?
        var shownRuns: [(tip: CoachTip, start: Double, end: Double)] = []
        var current: (CoachTip, Double)?
        simulate(seconds: 200, blurPerSecond: 1, pose: { loop($0, pitch: 0, height: 0) }, coach: &coach) { t, s in
            if s.tip != nil, firstTipAt == nil { firstTipAt = t }
            if current?.0 != s.tip {
                if let c = current { shownRuns.append((c.0, c.1, t)) }
                current = s.tip.map { ($0, t) }
            }
        }
        expect((firstTipAt ?? 99) >= quietStart, "no tip in the first 5 s (first at \(firstTipAt ?? -1))")
        let tooShort = shownRuns.filter { $0.end - $0.start < minDisplay - 0.01 }
        expect(tooShort.isEmpty, "every tip stays at least 4 s (\(tooShort))")
        let tooLong = shownRuns.filter { $0.end - $0.start > maxDisplay + 0.3 }
        expect(tooLong.isEmpty, "no tip stays beyond 12 s (\(tooLong))")
        for tip in CoachTip.allCases {
            let starts = shownRuns.filter { $0.tip == tip }
            for (a, b) in zip(starts, starts.dropFirst()) {
                expect(b.start - a.end >= cooldown - 0.3, "\(tip) respects cooldown (\(a.end) -> \(b.start))")
            }
        }
        return failures
    }
    #endif
}
