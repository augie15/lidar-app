import SwiftUI

/// Mesh and LiDAR options for the Settings form. Returns three sections, styled like the rest of Settings.
struct MeshSettingsSection: View {
    @AppStorage(AppSettings.Key.meshMode) private var mode = AppSettings.MeshMode.mesh.rawValue
    @AppStorage(AppSettings.Key.colorMesh) private var colorMesh = true
    @AppStorage(AppSettings.Key.depthConfidence) private var confidence = 1
    @AppStorage(AppSettings.Key.maxRange) private var maxRange = 3.0
    @AppStorage(AppSettings.Key.pointSpacing) private var spacing = 10
    @AppStorage(AppSettings.Key.smoothDepth) private var smoothDepth = true
    @AppStorage(AppSettings.Key.removePeople) private var removePeople = false
    @AppStorage(AppSettings.Key.highResVideo) private var highRes = false

    private var modeValue: AppSettings.MeshMode { AppSettings.MeshMode(rawValue: mode) ?? .mesh }
    private var confidenceValue: AppSettings.DepthConfidence { AppSettings.DepthConfidence(rawValue: confidence) ?? .medium }

    var body: some View {
        Section {
            segmented("Default mode", detail: modeValue.detail, selection: $mode) {
                ForEach(AppSettings.MeshMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            option("Color mesh scans", "Paints the mesh from the camera photos", $colorMesh)
        } header: { header("Mesh scan") } footer: {
            Text("Choose the mode again on the scan screen before you start.")
        }
        .listRowBackground(Theme.card)

        Section {
            segmented("Depth confidence", detail: confidenceValue.detail, selection: $confidence) {
                ForEach(AppSettings.DepthConfidence.allCases) { Text($0.title).tag($0.rawValue) }
            }
            segmented("Max range", detail: "Ignore points farther than this. LiDAR is most reliable up to about 5 m.",
                      selection: $maxRange) {
                Text("1.5 m").tag(1.5)
                Text("3 m").tag(3.0)
                Text("5 m").tag(5.0)
            }
            segmented("Point spacing", detail: "Smaller spacing gives denser point clouds and bigger files.",
                      selection: $spacing) {
                Text("5 mm").tag(5)
                Text("10 mm").tag(10)
                Text("20 mm").tag(20)
            }
            option("Smoothed depth", "Averages LiDAR depth over time for cleaner surfaces", $smoothDepth)
            option("Remove people", "Leaves out people who walk through the scan", $removePeople)
        } header: { header("LiDAR") } footer: {
            Text("Confidence, range and spacing apply to point clouds.")
        }
        .listRowBackground(Theme.card)

        Section {
            option("4K camera", "Records color at the camera's highest resolution", $highRes)
        } header: { header("Camera") } footer: {
            Text("Sharper color and photos, uses more battery")
        }
        .listRowBackground(Theme.card)
    }

    private func segmented<V: Hashable, Content: View>(_ title: String, detail: String, selection: Binding<V>,
                                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Picker(title, selection: selection) { content() }
                .pickerStyle(.segmented)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func option(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary).textCase(nil)
    }
}
