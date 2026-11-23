import ARKit
import AVFoundation
import SwiftUI

/// Controls the rear flashlight while an ARKit-based capture (RoomPlan, Object Capture, mesh) owns the camera.
@MainActor
@Observable
final class Torch {
    private(set) var isOn = false
    private(set) var isAvailable = false
    private var observation: NSKeyValueObservation?

    private let device: AVCaptureDevice? =
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

    init() {
        isAvailable = device?.hasTorch == true
        // ARKit may switch the torch off when it (re)starts a session; mirror the real hardware state.
        observation = device?.observe(\.isTorchActive, options: [.initial, .new]) { [weak self] device, _ in
            let active = device.isTorchActive
            Task { @MainActor in self?.isOn = active }
        }
    }

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            isOn = on
        } catch {
            isOn = device.isTorchActive
        }
    }
}

/// Round flashlight toggle sized to match the scan screens' close button. Turns the light off when it goes away.
struct TorchButton: View {
    @State private var torch = Torch()

    var body: some View {
        Group {
            if torch.isAvailable {
                Button { torch.toggle() } label: {
                    Image(systemName: torch.isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(torch.isOn ? ScanPalette.tealText : .white)
                        .frame(width: 40, height: 40)
                        .background(torch.isOn ? AnyShapeStyle(ScanPalette.teal) : AnyShapeStyle(.black.opacity(0.45)),
                                    in: Circle())
                }
                .accessibilityLabel(torch.isOn ? "Turn flash off" : "Turn flash on")
                .sensoryFeedback(.selection, trigger: torch.isOn)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .task {
            // "Flash on when a scan starts": ARKit can switch the torch off while its session spins up,
            // so turn it on after a short delay and once more if it got reset.
            guard AppSettings.flashOnStart, torch.isAvailable else { return }
            for delay in [1.0, 2.5] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                if !torch.isOn { torch.set(true) }
            }
        }
        .onDisappear { torch.set(false) }
    }
}
