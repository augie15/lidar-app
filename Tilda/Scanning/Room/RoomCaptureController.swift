import SwiftUI
import ARKit
import RoomPlan

/// Drives one RoomCaptureView/RoomCaptureSession. In whole-floor mode the same session and the same
/// ARSession run across every room (stop with pauseARSession: false), so all rooms and the photo
/// keyframes live in one world space.
@MainActor
final class RoomCaptureController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    enum Phase { case ready, scanning, between, processing }

    @Published var phase: Phase = .ready
    @Published private(set) var rooms: [CapturedRoom] = []
    var isMulti = false

    private(set) weak var captureView: RoomCaptureView?
    var onInstruction: ((String) -> Void)?
    var onPhotoCount: ((Int) -> Void)?
    var onRoomError: ((Error) -> Void)?
    private var completion: ((Result<CapturedRoom, Error>) -> Void)?
    private var stopped = false
    private(set) var recorder: FrameRecorder?
    private var poller: FramePoller?
    private var recorderDone = false

    override init() { super.init() }

    // NSCoding is required by RoomCaptureViewDelegate but never used.
    required init?(coder: NSCoder) { super.init() }
    nonisolated func encode(with coder: NSCoder) {}

    func attach(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
        view.captureSession.delegate = self
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        if AppSettings.capturePhotos {
            let recorder = FrameRecorder()
            let poller = FramePoller(session: view.captureSession.arSession, recorder: recorder)
            poller.onCount = { [weak self] in self?.onPhotoCount?($0) }
            poller.start()
            self.recorder = recorder
            self.poller = poller
        }
    }

    // MARK: Whole-floor steps

    /// Scanning -> between rooms. Keeps the AR session (and photo poller) running.
    func nextRoom() {
        guard phase == .scanning else { return }
        phase = .processing
        endRoom(pauseARSession: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let room): self.rooms.append(room)
            case .failure(let error): self.onRoomError?(error)
            }
            self.phase = .between
        }
    }

    /// Between rooms -> scanning, on the same session.
    func continueScanning() {
        guard phase == .between, let session = captureView?.captureSession else { return }
        session.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
    }

    /// Ends the scan and hands back every room scanned (the current one included when it processes).
    func finish(_ completion: @escaping (Result<[CapturedRoom], Error>) -> Void) {
        switch phase {
        case .scanning:
            phase = .processing
            endRoom(pauseARSession: true) { [weak self] result in
                guard let self else { return }
                self.poller?.stop()
                switch result {
                case .success(let room):
                    self.rooms.append(room)
                    completion(.success(self.rooms))
                case .failure(let error):
                    // A floor keeps the rooms it already has; a single room has nothing to save.
                    if self.rooms.isEmpty { completion(.failure(error)) } else { completion(.success(self.rooms)) }
                }
            }
        case .between:
            phase = .processing
            poller?.stop()
            stopped = true
            captureView?.captureSession.arSession.pause()
            completion(rooms.isEmpty ? .failure(RoomFlowError.noRooms) : .success(rooms))
        case .ready, .processing:
            break
        }
    }

    /// Returns to a state where Finish can be tried again after a failed save.
    func resumeAfterFailure() {
        phase = rooms.isEmpty ? .scanning : .between
    }

    private func endRoom(pauseARSession: Bool, _ completion: @escaping (Result<CapturedRoom, Error>) -> Void) {
        self.completion = completion
        if pauseARSession { stopped = true }
        captureView?.captureSession.stop(pauseARSession: pauseARSession)
    }

    // MARK: Teardown

    /// Discards photos unless they were already saved with a scan.
    func cancelRecorder() {
        poller?.stop()
        guard !recorderDone else { return }
        recorderDone = true
        recorder?.cancel()
    }

    func recorderConsumed() { recorderDone = true }

    func stop() {
        poller?.stop()
        guard !stopped else { return }
        stopped = true
        captureView?.captureSession.stop()
    }

    // MARK: RoomCaptureViewDelegate

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            guard let completion = self.completion else { return }
            self.completion = nil
            if let error { completion(.failure(error)) } else { completion(.success(processedResult)) }
        }
    }

    // MARK: RoomCaptureSessionDelegate

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String
        switch instruction {
        case .moveCloseToWall: text = "Move closer to the wall"
        case .moveAwayFromWall: text = "Move away from the wall"
        case .slowDown: text = "Slow down"
        case .turnOnLight: text = "Turn on more light"
        case .normal: text = "Looking good, keep going"
        case .lowTexture: text = "Point at a surface with more detail"
        @unknown default: text = "Walk slowly and point at walls, floor and corners"
        }
        Task { @MainActor in self.onInstruction?(text) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error {
            Task { @MainActor in
                guard let completion = self.completion else { return }
                self.completion = nil
                completion(.failure(error))
            }
        }
    }
}

enum RoomFlowError: LocalizedError {
    case noRooms
    var errorDescription: String? { "No rooms were scanned yet." }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: RoomCaptureController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
