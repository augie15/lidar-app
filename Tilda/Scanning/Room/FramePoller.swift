import ARKit
import Foundation

/// RoomPlan owns the ARSession delegate, so photos are collected by polling `currentFrame` ~10 times a second.
@MainActor
final class FramePoller {
    private weak var session: ARSession?
    private let recorder: FrameRecorder
    private var timer: Timer?
    private var lastTimestamp: TimeInterval = 0
    var onCount: ((Int) -> Void)?
    /// Camera pose and time of every new frame with good tracking.
    var onPose: ((simd_float4x4, TimeInterval) -> Void)?

    init(session: ARSession, recorder: FrameRecorder) {
        self.session = session
        self.recorder = recorder
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let frame = session?.currentFrame, frame.timestamp != lastTimestamp else { return }
        lastTimestamp = frame.timestamp
        recorder.consider(frame)
        onCount?(recorder.frameCount)
        if case .normal = frame.camera.trackingState { onPose?(frame.camera.transform, frame.timestamp) }
    }
}
