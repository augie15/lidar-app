import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Drives the photogrammetry reconstruction after capture has finished.
@MainActor
@Observable
final class ObjectReconstructionModel {
    enum Phase: Equatable {
        case idle
        case running
        case done(URL)
        case failed(String)
    }

    /// Photogrammetry options, read from Settings when a scan begins.
    struct Options: Sendable {
        var masking = true
        var highSensitivity = false
        var sequential = true
        static func fromSettings() -> Options {
            Options(masking: AppSettings.objectMasking,
                    highSensitivity: AppSettings.objectHighSensitivity,
                    sequential: AppSettings.objectSequential)
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var remaining: TimeInterval?
    private(set) var stageText: String = "Preparing"

    @ObservationIgnored private var session: PhotogrammetrySession?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(imagesDir: URL, checkpointDir: URL, outputURL: URL, options: Options = .fromSettings()) {
        guard phase != .running else { return }
        guard PhotogrammetrySession.isSupported else {
            phase = .failed("This device can't build 3D models from photos.")
            return
        }
        phase = .running
        progress = 0
        remaining = nil
        stageText = "Preparing"
        try? FileManager.default.removeItem(at: outputURL)

        task = Task { [weak self] in
            do {
                var config = PhotogrammetrySession.Configuration()
                config.checkpointDirectory = checkpointDir
                config.isObjectMaskingEnabled = options.masking
                config.featureSensitivity = options.highSensitivity ? .high : .normal
                config.sampleOrdering = options.sequential ? .sequential : .unordered
                let session = try PhotogrammetrySession(input: imagesDir, configuration: config)
                self?.session = session
                let request = PhotogrammetrySession.Request.modelFile(url: outputURL)
                try session.process(requests: [request])

                var finished = false
                for try await output in session.outputs {
                    guard let self else { return }
                    switch output {
                    case .requestProgress(_, let fraction):
                        self.progress = fraction
                    case .requestProgressInfo(_, let info):
                        self.remaining = info.estimatedRemainingTime
                        if let stage = info.processingStage { self.stageText = Self.text(for: stage) }
                    case .requestComplete(_, .modelFile(let url)):
                        finished = true
                        self.progress = 1
                        self.phase = .done(url)
                    case .requestError(_, let error):
                        self.phase = .failed(error.localizedDescription)
                        return
                    case .processingCancelled:
                        return
                    case .processingComplete:
                        if !finished { self.phase = .failed("No model was produced. Try capturing more photos.") }
                    default:
                        break
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        session?.cancel()
        task?.cancel()
        session = nil
        task = nil
    }

    private static func text(for stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: "Preparing photos"
        case .imageAlignment: "Aligning photos"
        case .pointCloudGeneration: "Building point cloud"
        case .meshGeneration: "Building mesh"
        case .textureMapping: "Applying textures"
        case .optimization: "Optimizing"
        @unknown default: "Processing"
        }
    }
}

extension ObjectCaptureSession.Feedback {
    var hintText: String {
        switch self {
        case .objectTooClose: "Move back a little"
        case .objectTooFar: "Move closer"
        case .movingTooFast: "Slow down"
        case .environmentLowLight, .environmentTooDark: "Find more light"
        case .outOfFieldOfView: "Keep the object in view"
        case .objectNotFlippable: "This object can't be flipped"
        case .overCapturing: "Plenty of photos here, move on"
        case .objectNotDetected: "Point at your object"
        @unknown default: ""
        }
    }
}
