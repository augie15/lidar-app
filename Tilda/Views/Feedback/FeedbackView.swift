import SwiftUI
import SafariServices
import MessageUI

struct FeedbackView: View {
    @Environment(\.openURL) private var openURL

    @State private var kind: FeedbackKind = .problem
    @State private var title = ""
    @State private var details = ""
    @State private var scanMode = ""
    @State private var showTitleError = false
    @State private var safariURL: IdentifiableURL?
    @State private var mailDraft: MailDraft?
    @FocusState private var titleFocused: Bool

    private let diagnostics = FeedbackDiagnostics.current

    private var titleIsEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: $title, prompt: Text(kind.titlePrompt).foregroundStyle(Theme.textMuted))
                        .focused($titleFocused)
                        .submitLabel(.next)
                        .accessibilityLabel("Title")
                        .onChange(of: title) { _, _ in if !titleIsEmpty { showTitleError = false } }
                    if showTitleError {
                        Text("Add a short title so we can tell reports apart.")
                            .font(.footnote)
                            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                    }
                }
                .padding(.vertical, 2)

                ZStack(alignment: .topLeading) {
                    if details.isEmpty {
                        Text(kind.detailsPrompt)
                            .foregroundStyle(Theme.textMuted)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $details)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .accessibilityLabel("Details")
                }

                if kind == .problem {
                    Picker("Scan mode", selection: $scanMode) {
                        Text("Not sure").tag("")
                        ForEach(FeedbackConfig.scanModes, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: { header(kind == .problem ? "Problem" : "Idea") }
            .listRowBackground(Theme.card)

            Section {
                DisclosureGroup("Included with your report") {
                    row("App version", diagnostics.appVersionAndBuild)
                    row("iOS version", diagnostics.iOSVersion)
                    row("Device", diagnostics.deviceModel)
                }
                .foregroundStyle(Theme.textPrimary)
            } footer: {
                Text("No scans or personal data are included.")
            }
            .listRowBackground(Theme.card)

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        Text("Continue on GitHub").fontWeight(.semibold)
                        Image(systemName: "arrow.up.right").font(.footnote.weight(.bold))
                        Spacer()
                    }
                    .foregroundStyle(Theme.background)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Theme.accent)

                if let email = FeedbackConfig.supportEmail {
                    Button("Send by email instead") { sendEmail(email) }
                        .listRowBackground(Theme.card)
                }
            } footer: {
                Text("Opens GitHub. You'll need a free GitHub account to submit, and your report will be public.")
            }
        }
        .tint(Theme.accent)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Send feedback")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $mailDraft) { draft in
            MailComposeView(draft: draft).ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary).textCase(nil)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard !titleIsEmpty else {
            showTitleError = true
            titleFocused = true
            return
        }
        let mode = kind == .problem ? scanMode : nil
        if let url = FeedbackURLBuilder.url(kind: kind, title: title, details: details,
                                            scanMode: mode, diagnostics: diagnostics) {
            safariURL = IdentifiableURL(url: url)
        }
    }

    private func sendEmail(_ email: String) {
        guard !titleIsEmpty else { showTitleError = true; titleFocused = true; return }
        let mode = kind == .problem ? scanMode : nil
        let subject = FeedbackURLBuilder.emailSubject(kind: kind, title: title)
        let body = FeedbackURLBuilder.emailBody(details: details, scanMode: mode, diagnostics: diagnostics)
        if MFMailComposeViewController.canSendMail() {
            mailDraft = MailDraft(to: email, subject: subject, body: body)
        } else if let url = FeedbackURLBuilder.mailto(email: email, kind: kind, title: title, details: details,
                                                      scanMode: mode, diagnostics: diagnostics) {
            openURL(url)
        }
    }
}

struct MailDraft: Identifiable {
    let id = UUID()
    let to: String
    let subject: String
    let body: String
}

private struct MailComposeView: UIViewControllerRepresentable {
    let draft: MailDraft
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([draft.to])
        vc.setSubject(draft.subject)
        vc.setMessageBody(draft.body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
