import SwiftUI
import UIKit

/// "Insights" card on the scan detail screen: summary, measured facts, tags and recognized text.
/// Everything here was produced on this iPhone.
struct InsightsCard: View {
    let insights: ScanInsights?
    let busy: Bool
    let onAnalyze: () -> Void

    @State private var showAllFacts = false
    @State private var copied: String?

    private let collapsedFactCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let insights {
                if !insights.summary.isEmpty {
                    Text(insights.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = ScanIntelligence.unavailableNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
                if !insights.facts.isEmpty { facts(insights.facts) }
                if !insights.tags.isEmpty { tags(insights.tags) }
                if !insights.recognizedText.isEmpty { recognized(insights.recognizedText) }
            } else if busy {
                Text("Reading this scan on your iPhone…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            } else {
                Text("Measurements, tags and a short summary, worked out on this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                if let note = ScanIntelligence.unavailableNote {
                    Text(note).font(.footnote).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: showAllFacts)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Insights")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("On-device")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.tile, in: Capsule())
            Spacer()
            Button(action: onAnalyze) {
                ZStack {
                    if busy {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Label(insights == nil ? "Analyze" : "Re-analyze", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.accentText)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(busy)
            .accessibilityLabel(busy ? "Analyzing" : (insights == nil ? "Analyze scan" : "Re-analyze scan"))
        }
    }

    private func facts(_ all: [ScanInsights.Fact]) -> some View {
        let shown = showAllFacts ? all : Array(all.prefix(collapsedFactCount))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider().overlay(Theme.separator) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(fact.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Text(fact.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            if all.count > collapsedFactCount {
                Button { showAllFacts.toggle() } label: {
                    Text(showAllFacts ? "Show fewer" : "Show all \(all.count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accentText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func tags(_ tags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.footnote)
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.tile, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: " + tags.joined(separator: ", "))
    }

    private func recognized(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text on the object")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button {
                        UIPasteboard.general.string = item
                        copied = item
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { try? await Task.sleep(for: .seconds(1.5)); if copied == item { copied = nil } }
                    } label: {
                        Label(copied == item ? "Copied" : item,
                              systemImage: copied == item ? "checkmark" : "doc.on.doc")
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Copy \(item)")
                }
            }
        }
    }
}
