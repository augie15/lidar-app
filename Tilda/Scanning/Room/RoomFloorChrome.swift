import SwiftUI

/// "One room | Whole floor" segmented pill, shown before the scan starts.
struct RoomModePill: View {
    @Binding var isFloor: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("One room", selected: !isFloor) { isFloor = false }
            segment("Whole floor", selected: isFloor) { isFloor = true }
        }
        .padding(3)
        .background(.black.opacity(0.45), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: isFloor)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? ScanPalette.tealText : .white)
                .padding(.horizontal, 16)
                .frame(minHeight: 38)
                .background(selected ? ScanPalette.teal : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small "Rooms: 3" chip shown during a floor scan.
struct RoomCountChip: View {
    let count: Int

    var body: some View {
        Text("Rooms: \(count)")
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .accessibilityLabel("\(count) rooms scanned")
    }
}

/// Bottom bar with a hint, a primary teal button and an optional secondary button beside it.
struct RoomActionBar: View {
    let hint: String
    let primaryTitle: String
    var secondaryTitle: String?
    var isProcessing = false
    var primaryEnabled = true
    let onPrimary: () -> Void
    var onSecondary: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Text(hint)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())
            HStack(spacing: 10) {
                if let secondaryTitle {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    }
                    .disabled(isProcessing)
                }
                Button(action: onPrimary) {
                    HStack(spacing: 8) {
                        if isProcessing { ProgressView().tint(ScanPalette.tealText) }
                        Text(isProcessing ? "Processing…" : primaryTitle)
                            .font(.headline)
                    }
                    .foregroundStyle(ScanPalette.tealText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(ScanPalette.teal, in: Capsule())
                    .opacity(isProcessing || !primaryEnabled ? 0.6 : 1)
                }
                .disabled(isProcessing || !primaryEnabled)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
    }
}
