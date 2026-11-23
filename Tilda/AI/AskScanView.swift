import FoundationModels
import SwiftUI

/// A message in the Ask chat.
private struct ChatMessage: Identifiable {
    let id = UUID()
    let fromUser: Bool
    var text: String
    var failed = false
}

/// Chat sheet that answers questions about one scan with the on-device Apple Intelligence model.
/// Tools return exact numbers from the scan files; nothing leaves the iPhone.
struct AskScanView: View {
    let scan: Scan
    let folder: URL
    let modelURL: URL
    let insights: ScanInsights?

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var session: LanguageModelSession?
    @State private var responding = false
    @FocusState private var focused: Bool

    private let examples = ["How much paint for the walls?", "Will a 2 m sofa fit?", "Describe this room for a listing"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            intro
                            if messages.isEmpty { chips }
                            ForEach(messages) { bubble($0).id($0.id) }
                        }
                        .padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.last?.text) { _, _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                composer
            }
            .background(Theme.background)
            .navigationTitle("Ask about this scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .task { await prepare() }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "apple.intelligence")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Answers come from Apple Intelligence running on this iPhone, using measurements from \(scan.name). Nothing is sent anywhere.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(examples, id: \.self) { example in
                Button { send(example) } label: {
                    Text(example)
                        .font(.subheadline)
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.featured, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(session == nil)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.fromUser { Spacer(minLength: 48) }
            Group {
                if message.text.isEmpty && !message.fromUser {
                    ProgressView().tint(Theme.accent)
                } else {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.failed ? Theme.textSecondary : Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.fromUser ? Theme.featured : Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
            if !message.fromUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((message.fromUser ? "You: " : "Answer: ") + message.text)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a question", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canSend ? Theme.background : Theme.textMuted)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Theme.accent : Theme.card, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    private var canSend: Bool {
        session != nil && !responding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Session

    private func prepare() async {
        guard session == nil, SystemLanguageModel.default.availability == .available else { return }
        let measurements = await ScanMeasurements.load(folder: folder, modelURL: modelURL)
        let tools: [any Tool] = [
            RoomFactsTool(measurements: measurements),
            WallLengthsTool(measurements: measurements),
            SurfaceAreasTool(measurements: measurements),
            ObjectDimensionsTool(measurements: measurements),
            PaintEstimateTool(measurements: measurements),
            FitCheckTool(measurements: measurements),
        ]
        var context = ["Scan name: \(scan.name)", "Scan type: \(scan.kind.title)"]
        if let insights {
            if !insights.summary.isEmpty { context.append("Summary: \(insights.summary)") }
            if !insights.facts.isEmpty {
                context.append("Facts:\n" + insights.facts.map { "- \($0.label): \($0.value)" }.joined(separator: "\n"))
            }
            if !insights.tags.isEmpty { context.append("Tags: " + insights.tags.joined(separator: ", ")) }
        }
        if let line = FixtureLibrary.load(folder: folder)?.summaryLine(lengthText: { MeasureFormat.length(Double($0)) }) {
            context.append("Fixtures found in the scan photos (vents, bathroom fans, baseboard heaters; may be incomplete): \(line)")
        }
        let instructions = """
        You answer questions about one 3D scan made with an iPhone LiDAR scanner. \
        For any number (areas, lengths, heights, counts, paint amounts) call a tool and copy the result exactly; \
        never measure, convert or estimate yourself. If the tools do not have the data, say you don't have it. \
        Show both units as the tool returns them. Keep answers short and practical. \
        For listing descriptions, use only facts you were given.

        \(context.joined(separator: "\n"))
        """
        session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), tools: tools,
                                       instructions: instructions)
        session?.prewarm()
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !responding, !question.isEmpty else { return }
        draft = ""
        focused = false
        messages.append(ChatMessage(fromUser: true, text: question))
        messages.append(ChatMessage(fromUser: false, text: ""))
        let index = messages.count - 1
        responding = true
        Task {
            defer { responding = false }
            do {
                for try await snapshot in session.streamResponse(to: question) {
                    messages[index].text = snapshot.content
                }
                if messages[index].text.isEmpty { messages[index].text = "I don't have an answer for that."; messages[index].failed = true }
            } catch {
                messages[index].text = "I couldn't answer that. Try rephrasing the question."
                messages[index].failed = true
            }
        }
    }
}
