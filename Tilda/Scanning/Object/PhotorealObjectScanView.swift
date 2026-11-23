import SwiftUI
import RealityKit

/// Photoreal object capture: guided capture with ObjectCaptureSession, then on-device
/// reconstruction with PhotogrammetrySession. Hosted by `ObjectScanView`.
struct PhotorealObjectScanView: View {
    @Binding var mode: AppSettings.ObjectMode
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var session: ObjectCaptureSession?
    @State private var reconstruction = ObjectReconstructionModel()
    @State private var workDir: URL?
    @State private var isReconstructing = false
    @State private var errorMessage: String?
    @State private var unsupported = false
    @State private var keepImages = false
    @State private var imported = false

    private let teal = Color(red: 0x5D / 255, green: 0xCA / 255, blue: 0xA5 / 255)
    private let tealText = Color(red: 0x04 / 255, green: 0x34 / 255, blue: 0x2C / 255)

    private var imagesDir: URL? { workDir?.appendingPathComponent("images", isDirectory: true) }
    private var checkpointDir: URL? { workDir?.appendingPathComponent("Checkpoint", isDirectory: true) }
    private var outputURL: URL? { workDir?.appendingPathComponent("model.usdz") }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isReconstructing {
                processingContent
            } else if let session {
                if session.userCompletedScanPass {
                    // Coverage preview: the point cloud built so far, before the user finishes.
                    ObjectCapturePointCloudView(session: session)
                        .ignoresSafeArea()
                } else {
                    ObjectCaptureView(session: session)
                        .ignoresSafeArea()
                }
                captureChrome(session)
            } else if unsupported {
                Text("Object scanning needs an iPhone with LiDAR.")
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(32)
            }

            topBar
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            startCaptureIfNeeded()
        }
        .onDisappear { tearDown() }
        .onChange(of: session?.state) { _, newState in
            handle(state: newState)
        }
        .onChange(of: reconstruction.phase) { _, phase in
            switch phase {
            case .done(let url): importModel(url)
            case .failed(let message): errorMessage = message
            default: break
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            if isReconstructing {
                Button("Retry") { startReconstruction() }
            }
            Button("Close", role: .cancel) { cancelAndDismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        // Torch only while the camera is live; the mode picker only before capture begins.
        ObjectScanTopBar(mode: canPickMode ? $mode : nil, showTorch: session != nil) { cancelAndDismiss() }
    }

    private var canPickMode: Bool {
        guard !isReconstructing else { return false }
        guard let session else { return unsupported }
        switch session.state {
        case .initializing, .ready, .detecting: return true
        default: return false
        }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tealText)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(teal, in: Capsule())
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
    }

    @ViewBuilder
    private func captureChrome(_ session: ObjectCaptureSession) -> some View {
        VStack(spacing: 12) {
            Spacer()
            switch session.state {
            case .ready:
                hint("Point at your object")
                keepImagesHint
                pillButton("Continue") { _ = session.startDetecting() }
            case .detecting:
                hint("Adjust the box to fit")
                pillButton("Start capture") { session.startCapturing() }
                secondaryButton("Reset") { session.resetDetection() }
            case .capturing:
                Text("\(session.numberOfShotsTaken) of \(session.maximumNumberOfInputImages) photos")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                let feedbackText = session.feedback.map(\.hintText).filter { !$0.isEmpty }.sorted().first
                if session.userCompletedScanPass {
                    hint("Pass complete. Check the coverage, then finish or scan another side.")
                    keepImagesHint
                    pillButton("Finish") { session.finish() }
                    secondaryButton("Scan another side") { session.beginNewScanPass() }
                } else {
                    hint(feedbackText ?? "Walk slowly around the object")
                    pillButton("Finish") { session.finish() }
                }
            case .initializing, .finishing, .completed:
                hint("Just a moment")
            case .failed:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var keepImagesHint: some View {
        if keepImages {
            hint("Photos are kept. Export \u{201C}Photos for Mac\u{201D} for full detail.")
        }
    }

    private var processingContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: reconstruction.progress)
                .tint(teal)
                .padding(.horizontal, 48)
            Text(reconstruction.stageText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text(progressDetail)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            Text("Keep Tilda open while your model is built.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            if keepImages {
                Text("Photos are kept. Export \u{201C}Photos for Mac\u{201D} for full detail.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    private var progressDetail: String {
        var text = "\(Int(reconstruction.progress * 100))%"
        if let remaining = reconstruction.remaining, remaining > 0 {
            let minutes = Int((remaining / 60).rounded(.up))
            text += minutes <= 1 ? " · about 1 min left" : " · about \(minutes) min left"
        }
        return text
    }

    // MARK: - Flow

    private func startCaptureIfNeeded() {
        guard session == nil, !isReconstructing, workDir == nil else { return }
        guard ObjectCaptureSession.isSupported, PhotogrammetrySession.isSupported else {
            unsupported = true
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObjectScan-\(UUID().uuidString)", isDirectory: true)
        let images = dir.appendingPathComponent("images", isDirectory: true)
        let checkpoint = dir.appendingPathComponent("Checkpoint", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        workDir = dir
        keepImages = AppSettings.objectKeepImages
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        config.isOverCaptureEnabled = AppSettings.objectOverCapture
        let newSession = ObjectCaptureSession()
        newSession.start(imagesDirectory: images, configuration: config)
        session = newSession
    }

    private func handle(state: ObjectCaptureSession.CaptureState?) {
        guard let state else { return }
        switch state {
        case .completed:
            // Release the capture session (and its view) before reconstruction to free memory.
            session = nil
            isReconstructing = true
            startReconstruction()
        case .failed(let error):
            session = nil
            errorMessage = error.localizedDescription
        default:
            break
        }
    }

    private func startReconstruction() {
        guard let imagesDir, let checkpointDir, let outputURL else { return }
        reconstruction.start(imagesDir: imagesDir, checkpointDir: checkpointDir, outputURL: outputURL,
                             options: .fromSettings())
    }

    private func importModel(_ url: URL) {
        do {
            // Kept photos travel with the scan as `images/` so the "Photos for Mac" export can zip them.
            let attachments = keepImages ? [imagesDir].compactMap { $0 } : []
            try store.importModel(at: url, kind: .object, mode: AppSettings.ObjectMode.photoreal.rawValue,
                                  attachments: attachments)
            imported = true
            cleanUp()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancelAndDismiss() {
        session?.cancel()
        session = nil
        reconstruction.cancel()
        cleanUp()
        dismiss()
    }

    /// Runs when the view goes away (close, dismiss, or a mode switch): stop everything and drop temp files.
    private func tearDown() {
        session?.cancel()
        session = nil
        if !imported { reconstruction.cancel() }
        cleanUp()
    }

    private func cleanUp() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
