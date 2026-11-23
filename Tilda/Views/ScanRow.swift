import SwiftUI

struct ScanRow: View {
    let scan: Scan

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: scan.kind.symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(scan.kind.title) · \(scan.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
