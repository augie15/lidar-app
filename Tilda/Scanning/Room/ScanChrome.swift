import SwiftUI

/// Shared colors and chrome pieces for the Room and Mesh scanners.
enum ScanPalette {
    static let teal = Color(red: 0x5D / 255, green: 0xCA / 255, blue: 0xA5 / 255)
    static let tealText = Color(red: 0x04 / 255, green: 0x34 / 255, blue: 0x2C / 255)
}

struct ScanTopBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())
            Spacer()
            TorchButton()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct ScanBottomBar: View {
    let hint: String
    let isProcessing: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(hint)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())
            Button(action: onDone) {
                HStack(spacing: 8) {
                    if isProcessing { ProgressView().tint(ScanPalette.tealText) }
                    Text(isProcessing ? "Processing…" : "Done")
                        .font(.headline)
                }
                .foregroundStyle(ScanPalette.tealText)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(ScanPalette.teal, in: Capsule())
                .opacity(isProcessing ? 0.8 : 1)
            }
            .disabled(isProcessing)
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
    }
}
