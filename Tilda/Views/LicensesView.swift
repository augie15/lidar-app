import SwiftUI

/// Open-source licences for the code behind 3D photos. The texts are bundled files in Resources/Licenses.
struct LicensesView: View {
    private struct Entry: Identifiable {
        let id: String
        let name: String
        let summary: String
        let file: String
    }

    private let entries = [
        Entry(id: "msplat", name: "msplat-ios", summary: "Apache License 2.0. Makes 3D photos on your iPhone. Includes notices for Brush and NVIDIA PPISP.", file: "License-msplat-ios"),
        Entry(id: "metalsplatter", name: "MetalSplatter", summary: "MIT License. Sean Cier. Draws 3D photos.", file: "License-MetalSplatter"),
        Entry(id: "spz", name: "spz-swift", summary: "MIT License. Niantic Labs and Sean Cier. Reads compressed 3D photo files.", file: "License-spz-swift"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        LicenseTextView(name: entry.name, file: entry.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).foregroundStyle(Theme.textPrimary)
                            Text(entry.summary).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text("Tilda uses these open-source projects. Their licences are shown as published.")
            }
            .listRowBackground(Theme.card)
        }
        .tint(Theme.accent)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Open-source licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let name: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Theme.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let string = try? String(contentsOf: url, encoding: .utf8) else { return "The licence text couldn't be loaded." }
        return string
    }
}
