import SwiftUI
import ARKit
import RealityKit
import RoomPlan

/// Whether this device can run each capture mode.
@MainActor enum DeviceSupport {
    static func isSupported(_ kind: ScanKind) -> Bool {
        switch kind {
        case .room: RoomCaptureSession.isSupported
        case .object: ObjectCaptureSession.isSupported
        case .mesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }

    static func unsupportedMessage(for kind: ScanKind) -> String {
        switch kind {
        case .room: "Room scans need an iPhone with a LiDAR scanner."
        case .object: "Object scans need an iPhone with a LiDAR scanner."
        case .mesh: "Mesh scans need an iPhone with a LiDAR scanner."
        }
    }
}
