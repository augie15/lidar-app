import SwiftUI

/// Object scan options for the Settings form. Returns two sections, styled like the rest of Settings.
struct ObjectSettingsSection: View {
    @AppStorage(AppSettings.Key.objectMode) private var mode = AppSettings.ObjectMode.photoreal.rawValue
    @AppStorage(AppSettings.Key.objectOverCapture) private var overCapture = true
    @AppStorage(AppSettings.Key.objectMasking) private var masking = true
    @AppStorage(AppSettings.Key.objectHighSensitivity) private var highSensitivity = false
    @AppStorage(AppSettings.Key.objectSequential) private var sequential = true
    @AppStorage(AppSettings.Key.objectKeepImages) private var keepImages = false

    private var modeValue: AppSettings.ObjectMode { AppSettings.ObjectMode(rawValue: mode) ?? .photoreal }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Default mode").foregroundStyle(Theme.textPrimary)
                Picker("Default mode", selection: $mode) {
                    ForEach(AppSettings.ObjectMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(modeValue.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 4)

            option("Extra shots", "Takes more photos for a better model", $overCapture)
            option("Keep the surface under the object", "Leave the table or floor in the model", keepSurface)
            option("High sensitivity for plain objects", "Helps with smooth objects that have little texture", $highSensitivity)
            option("Faster processing", "Assumes photos were taken in order while walking around", $sequential)
        } header: { header("Object") }
        .listRowBackground(Theme.card)

        Section {
            option("Keep photos for Mac", "Saves the capture photos with the scan", $keepImages)
        } header: { header("Object photos") } footer: {
            Text("iPhone builds models at reduced detail. Export the photos to build full or raw detail on a Mac.")
        }
        .listRowBackground(Theme.card)
    }

    /// Masking is on by default; the setting reads the other way round for people.
    private var keepSurface: Binding<Bool> {
        Binding(get: { !masking }, set: { masking = !$0 })
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
