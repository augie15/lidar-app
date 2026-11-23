import Foundation
import RoomPlan

/// Turns captured rooms into the files a Room scan saves: model, floorplan.json, roomfacts.json, frames/.
enum RoomExporter {
    enum Strategy: Sendable {
        /// Merge all rooms with `StructureBuilder` and export one model.
        case merged
        /// Merge failed: export only the largest room's model. Plan and facts still cover every room.
        case largestRoomOnly
    }

    struct Output: Sendable {
        var model: URL
        var attachments: [URL]
    }

    /// Runs off the main thread. Photos are only finalized once the model exists, so a failure can be retried.
    static func prepare(rooms: [CapturedRoom], strategy: Strategy, recorder: FrameRecorder?) async throws -> Output {
        let detail = AppSettings.roomDetail
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let model = dir.appendingPathComponent("room.usdz")
            // Simple = parametric boxes (light, quick). Detailed = mesh. Falls back to the other on failure.
            let order: [CapturedRoom.USDExportOptions] = detail == .simple ? [.parametric, .mesh] : [.mesh, .parametric]

            var structure: CapturedStructure?
            var factRooms = rooms
            if rooms.count > 1 {
                switch strategy {
                case .merged:
                    let built = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                    do {
                        try built.export(to: model, metadataURL: nil, modelProvider: nil, exportOptions: order[0])
                    } catch {
                        try built.export(to: model, metadataURL: nil, modelProvider: nil, exportOptions: order[1])
                    }
                    structure = built
                    if !built.rooms.isEmpty { factRooms = built.rooms }
                case .largestRoomOnly:
                    let largest = rooms.max { RoomFactsBuilder.floorArea(of: $0) < RoomFactsBuilder.floorArea(of: $1) } ?? rooms[0]
                    try exportRoom(largest, to: model, order: order)
                }
            } else if let only = rooms.first {
                try exportRoom(only, to: model, order: order)
            }

            var attachments: [URL] = []
            let planURL = dir.appendingPathComponent(FloorPlan.fileName)
            let plan = structure.map { FloorPlanBuilder.build(from: $0) } ?? FloorPlanBuilder.build(from: rooms)
            if (try? plan.write(to: planURL)) != nil { attachments.append(planURL) }

            let factsURL = dir.appendingPathComponent(RoomFacts.fileName)
            if (try? RoomFactsBuilder.build(from: factRooms).write(to: factsURL)) != nil { attachments.append(factsURL) }

            if let frames = recorder?.finish() { attachments.append(frames) }
            return Output(model: model, attachments: attachments)
        }.value
    }

    private static func exportRoom(_ room: CapturedRoom, to url: URL, order: [CapturedRoom.USDExportOptions]) throws {
        do {
            try room.export(to: url, exportOptions: order[0])
        } catch {
            try room.export(to: url, exportOptions: order[1])
        }
    }
}
