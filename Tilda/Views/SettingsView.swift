import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store

    @AppStorage(AppSettings.Key.capturePhotos) private var capturePhotos = true
    @AppStorage(AppSettings.Key.scanningTips) private var scanningTips = true
    @AppStorage(AppSettings.Key.photoDensity) private var density = AppSettings.PhotoDensity.standard.rawValue
    @AppStorage(AppSettings.Key.roomDetail) private var roomDetail = AppSettings.RoomDetail.simple.rawValue
    @AppStorage(AppSettings.Key.flashOnStart) private var flashOnStart = false
    @AppStorage(AppSettings.Key.units) private var units = AppSettings.Units.imperial.rawValue
    @AppStorage(AppSettings.Key.wallThickness) private var wallThickness = 0.15
    @AppStorage("aiAutoAnalyze") private var aiAutoAnalyze = true
    @AppStorage(AppSettings.Key.scanFocus) private var scanFocus = ScanFocus.general.rawValue

    @State private var storageText = "Calculating…"

    private var densityValue: AppSettings.PhotoDensity { AppSettings.PhotoDensity(rawValue: density) ?? .standard }
    private var detailValue: AppSettings.RoomDetail { AppSettings.RoomDetail(rawValue: roomDetail) ?? .simple }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Save photos with scans", isOn: $capturePhotos)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Photo density")
                            .foregroundStyle(capturePhotos ? Theme.textPrimary : Theme.textMuted)
                        Picker("Photo density", selection: $density) {
                            ForEach(AppSettings.PhotoDensity.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        Text(densityValue.detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                    .disabled(!capturePhotos)
                    Toggle("Flash on when a scan starts", isOn: $flashOnStart)
                    Picker("Units", selection: $units) {
                        ForEach(AppSettings.Units.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: { header("General") } footer: {
                    Text("Photos power the photo tour, mesh color and the Photos + poses export.")
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle("Scanning tips", isOn: $scanningTips)
                        .disabled(!capturePhotos)
                } header: { header("Guidance") } footer: {
                    Text("Reminds you to change height and angle as you scan, which helps 3D photos and fixture detection.")
                }
                .listRowBackground(Theme.card)

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Room model detail").foregroundStyle(Theme.textPrimary)
                        Picker("Room model detail", selection: $roomDetail) {
                            ForEach(AppSettings.RoomDetail.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        Text(detailValue.detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                    Picker("Wall thickness", selection: $wallThickness) {
                        if units == AppSettings.Units.metric.rawValue {
                            Text("10 cm").tag(0.10); Text("15 cm").tag(0.15); Text("20 cm").tag(0.20)
                        } else {
                            Text("4″").tag(0.10); Text("6″").tag(0.15); Text("8″").tag(0.20)
                        }
                    }
                } header: { header("Room") } footer: {
                    Text("Used for estimated gross area. Interior walls are usually 4–5″, exterior walls 6–8″.")
                }
                .listRowBackground(Theme.card)

                ObjectSettingsSection()
                MeshSettingsSection()

                Section {
                    Toggle("Name, summarize and check new scans", isOn: $aiAutoAnalyze)
                    Picker("What do you scan for?", selection: $scanFocus) {
                        ForEach(ScanFocus.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: { header("Apple Intelligence") } footer: {
                    Text((ScanFocus(rawValue: scanFocus) ?? .general).detail + ". Applies to new analyses; re-analyze a scan to rewrite it.\n\nNames and summaries, plus a look through room scan photos for vents, bathroom fans and baseboard heaters. Runs on your iPhone with Apple Intelligence. Nothing leaves your device.")
                }
                .listRowBackground(Theme.card)

                Section {
                    HStack {
                        Text("Scans on this iPhone").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(storageText).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                } header: { header("Storage") }
                .listRowBackground(Theme.card)

                Section {
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        Label("Send feedback", systemImage: "bubble.left.and.text.bubble.right")
                            .foregroundStyle(Theme.textPrimary)
                    }
                } header: { header("Feedback") } footer: {
                    Text("Report a problem or suggest a feature.")
                }
                .listRowBackground(Theme.card)

                Section {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Open-source licences", systemImage: "doc.text")
                            .foregroundStyle(Theme.textPrimary)
                    }
                } header: { header("Legal") }
                .listRowBackground(Theme.card)

                Section {
                    Text("Tilda · The Instant LiDAR Digitizing App · Free, private, on-device")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Color.clear)
                } header: { header("About") }
            }
            .tint(Theme.accent)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .task { await computeStorage() }
        }
        .preferredColorScheme(.dark)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary).textCase(nil)
    }

    private func computeStorage() async {
        let root = store.rootURL
        let bytes: Int64 = await Task.detached {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            }
            return total
        }.value
        storageText = bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
