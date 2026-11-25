import SwiftUI
import RoomPlan

/// Full-screen RoomPlan capture of one room or a whole floor. Saves a .usdz into the library.
struct RoomScanView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("roomMultiMode") private var multiMode = false

    @StateObject private var controller = RoomCaptureController()
    @State private var errorMessage: String?
    @State private var dismissOnError = true
    @State private var hint = "Walk slowly and point at walls, floor and corners"
    @State private var photoCount = 0
    @State private var askSaveOnClose = false
    @State private var mergeFailed = false
    @State private var pendingRooms: [CapturedRoom] = []

    private var phase: RoomCaptureController.Phase { controller.phase }

    var body: some View {
        ZStack {
            if phase != .ready && RoomCaptureSession.isSupported {
                RoomCaptureRepresentable(controller: controller)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                ScanTopBar(title: "Room scan") { close() }
                if phase == .ready {
                    RoomModePill(isFloor: $multiMode)
                } else if controller.isMulti {
                    RoomCountChip(count: controller.rooms.count)
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if phase == .scanning, let coach = controller.coach { ScanCoachPill(model: coach) }
                bottomBar
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            controller.onInstruction = { hint = $0 }
            controller.onPhotoCount = { photoCount = $0 }
            controller.onRoomError = { _ in
                dismissOnError = false
                errorMessage = "That room couldn't be processed. Walk back and scan it again, or continue to the next one."
            }
            if !RoomCaptureSession.isSupported {
                errorMessage = "Room scanning needs an iPhone with a LiDAR scanner."
            }
        }
        .onDisappear {
            controller.stop()
            controller.cancelRecorder()
        }
        .alert("Scan failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {
                if dismissOnError { dismiss() }
                dismissOnError = true
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Save what you've scanned?", isPresented: $askSaveOnClose, titleVisibility: .visible) {
            Button("Save \(roomsLabel(controller.rooms.count))") { finish() }
            Button("Discard", role: .destructive) { teardown(); dismiss() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("You have \(roomsLabel(controller.rooms.count)) scanned so far.")
        }
        .confirmationDialog("Couldn't merge the rooms", isPresented: $mergeFailed, titleVisibility: .visible) {
            Button("Save largest room") { save(rooms: pendingRooms, strategy: .largestRoomOnly) }
            Button("Try merging again") { save(rooms: pendingRooms, strategy: .merged) }
            Button("Discard", role: .destructive) { teardown(); dismiss() }
        } message: {
            Text("RoomPlan couldn't join them into one model. You can save the largest room's 3D model. The floor plan, measurements and photos still cover all \(pendingRooms.count) rooms.")
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var bottomBar: some View {
        switch phase {
        case .ready:
            RoomActionBar(hint: multiMode
                          ? "Scan each room in turn. Rooms are joined into one floor."
                          : "Scan a single room.",
                          primaryTitle: "Start scanning") { start() }
        case .scanning where !controller.isMulti:
            ScanBottomBar(hint: displayHint, isProcessing: false) { finish() }
        case .scanning:
            RoomActionBar(hint: displayHint, primaryTitle: "Next room", secondaryTitle: "Finish floor") {
                controller.nextRoom()
            } onSecondary: { finish() }
        case .between:
            RoomActionBar(hint: "Walk to the next room, then tap Continue",
                          primaryTitle: "Continue", secondaryTitle: "Finish floor") {
                hint = "Walk slowly and point at walls, floor and corners"
                controller.continueScanning()
            } onSecondary: { finish() }
        case .processing:
            RoomActionBar(hint: "Hold on, building your \(controller.isMulti ? "floor" : "room")",
                          primaryTitle: "Done", isProcessing: true) {}
        }
    }

    private var displayHint: String {
        photoCount > 0 ? "\(hint) · \(photoCount) photos" : hint
    }

    private func roomsLabel(_ n: Int) -> String { n == 1 ? "1 room" : "\(n) rooms" }

    // MARK: Actions

    private func start() {
        guard RoomCaptureSession.isSupported else { return }
        controller.isMulti = multiMode
        controller.phase = .scanning
    }

    private func close() {
        if controller.isMulti, !controller.rooms.isEmpty, phase != .processing {
            askSaveOnClose = true
        } else {
            teardown()
            dismiss()
        }
    }

    private func teardown() {
        controller.stop()
        controller.cancelRecorder()
    }

    private func finish() {
        guard phase != .processing else { return }
        controller.finish { result in
            switch result {
            case .success(let rooms):
                save(rooms: rooms, strategy: .merged)
            case .failure(let error):
                controller.resumeAfterFailure()
                dismissOnError = true
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save(rooms: [CapturedRoom], strategy: RoomExporter.Strategy) {
        controller.phase = .processing
        let recorder = controller.recorder
        let isFloor = controller.isMulti && rooms.count > 1
        Task {
            do {
                let built = try await RoomExporter.prepare(rooms: rooms, strategy: strategy, recorder: recorder)
                try store.importModel(at: built.model, kind: .room, mode: isFloor ? "floor" : "room",
                                      attachments: built.attachments)
                controller.recorderConsumed()
                dismiss()
            } catch {
                if isFloor && strategy == .merged {
                    pendingRooms = rooms
                    controller.resumeAfterFailure()
                    mergeFailed = true
                } else {
                    controller.resumeAfterFailure()
                    // A single room can't be resumed once stopped; a floor keeps its rooms so Finish can retry.
                    dismissOnError = !controller.isMulti
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
