import SwiftUI

struct ModeTile: View {
    let kind: ScanKind
    var featured = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: kind.symbol)
                    .font(.system(size: featured ? 30 : 24, weight: .regular))
                    .foregroundStyle(featured ? Theme.accent : Theme.accentText)
                    .accessibilityHidden(true)
                Spacer(minLength: 16)
                Text(kind.title)
                    .font(featured ? .title2.weight(.semibold) : .headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.tagline)
                    .font(.subheadline)
                    .foregroundStyle(featured ? Theme.accentText : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: featured ? 128 : 116, alignment: .leading)
            .padding(18)
            .background(featured ? Theme.featured : Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(kind.title) scan")
        .accessibilityHint(kind.tagline)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
