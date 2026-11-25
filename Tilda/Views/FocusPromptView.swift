import SwiftUI

/// One-time "What do you scan for?" sheet. General is pre-selected and fine to keep; skipping keeps General.
/// Dismissing in any way marks the question answered (HomeView's onDismiss).
struct FocusPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = AppSettings.focus

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What do you scan for?")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Tilda writes each scan's summary to suit it. General works for everything.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(ScanFocus.allCases) { focus in row(focus) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .padding(.bottom, 16)
            }
            VStack(spacing: 4) {
                Button(action: confirm) {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                Button { selection = .general; confirm() } label: {
                    Text("Skip for now")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                Text("You can change this later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(false)
    }

    private func row(_ focus: ScanFocus) -> some View {
        let selected = selection == focus
        return Button {
            selection = focus
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: focus.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.tile, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(focus.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(selected ? Theme.featured : Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func confirm() {
        UserDefaults.standard.set(selection.rawValue, forKey: AppSettings.Key.scanFocus)
        dismiss()
    }
}
