import Combine
import Foundation
import SwiftUI
import simd

/// Feeds AR frames to a `ScanCoach` and publishes what to show. Safe to call from any thread.
///
/// Cost per AR frame is one lock and a time compare; the real work runs ~4 times a second.
final class ScanCoachModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var state = ScanCoach.State()

    private let lock = NSLock()
    private var coach = ScanCoach()
    private var lastTime = -Double.infinity
    private var published = ScanCoach.State()
    private static let interval: TimeInterval = 0.25

    /// Call for every AR frame with good tracking. `recorder` supplies the photo and blur counts.
    func ingest(transform: simd_float4x4, time: TimeInterval, recorder: FrameRecorder) {
        let new: ScanCoach.State? = lock.withLock {
            guard time - lastTime >= Self.interval else { return nil }
            lastTime = time
            let c = recorder.coachCounts
            let col = transform.columns
            let next = coach.ingest(position: SIMD3(col.3.x, col.3.y, col.3.z),
                                    forward: simd_normalize(-SIMD3(col.2.x, col.2.y, col.2.z)),
                                    time: time, keptTotal: c.kept, blurSkippedTotal: c.blurSkipped)
            guard next != published else { return nil }
            published = next
            return next
        }
        guard let new else { return }
        DispatchQueue.main.async { [weak self] in self?.state = new }
    }
}

/// The hint pill. Sits above the bottom hint on the scan screens: same black capsule as the hint, with a teal icon.
struct ScanCoachPill: View {
    @ObservedObject var model: ScanCoachModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(for: model.state)
            .frame(minHeight: 34, alignment: .bottom)
            .animation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.3), value: model.state)
            .sensoryFeedback(trigger: model.state.tip) { old, new in
                // One light tap when a new tip appears, nothing when it goes away.
                new != nil && new != old ? .impact(flexibility: .soft, intensity: 0.5) : nil
            }
            .onChange(of: model.state.tip) { _, tip in
                // Low priority so VoiceOver finishes what it is reading first.
                guard let tip else { return }
                var text = AttributedString(tip.text)
                text.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(text).post()
            }
    }

    @ViewBuilder
    private func content(for state: ScanCoach.State) -> some View {
        if let tip = state.tip {
            ScanCoachLabel(text: tip.text, symbol: tip.symbol, tinted: true)
                .id(tip)
                .transition(transition)
        } else if state.goodCoverage {
            ScanCoachLabel(text: "Good coverage", symbol: "checkmark.circle", tinted: false)
                .id("good")
                .transition(transition)
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

struct ScanCoachLabel: View {
    let text: String
    let symbol: String
    /// Tips get a teal icon; the quiet "good" state stays white.
    let tinted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tinted ? ScanPalette.teal : .white.opacity(0.7))
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tinted ? .white : .white.opacity(0.7))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// `-TildaCoachPreview <tip|good>` shows the scan chrome with a fake camera and that hint, for screenshots in the
/// Simulator (no scanning there). Add `-TildaCoachPreviewType XXL` style flags via the simulator's own settings.
struct ScanCoachPreviewScreen: View {
    let tip: CoachTip?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) { ScanTopBar(title: "Room scan") {} }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                ScanCoachLabel(text: tip?.text ?? "Good coverage", symbol: tip?.symbol ?? "checkmark.circle",
                               tinted: tip != nil)
                ScanBottomBar(hint: "Walk slowly and point at walls, floor and corners · 84 photos",
                              isProcessing: false) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
