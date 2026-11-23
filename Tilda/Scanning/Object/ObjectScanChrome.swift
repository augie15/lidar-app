import SwiftUI

/// Compact segmented pill (Photoreal | LiDAR quick) shown before capture starts.
struct ObjectModePicker: View {
    @Binding var mode: AppSettings.ObjectMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSettings.ObjectMode.allCases) { option in
                let selected = option == mode
                Button { mode = option } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? ScanPalette.tealText : .white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(selected ? ScanPalette.teal : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.black.opacity(0.5), in: Capsule())
        .sensoryFeedback(.selection, trigger: mode)
        .animation(.easeOut(duration: 0.2), value: mode)
    }
}

/// Top bar shared by both Object flows: close, title, flash, and (before capture) the mode picker.
struct ObjectScanTopBar: View {
    var mode: Binding<AppSettings.ObjectMode>?
    var showTorch: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    if showTorch { TorchButton() } else { Color.clear.frame(width: 40, height: 40) }
                }
                Text("Object scan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            if let mode { ObjectModePicker(mode: mode) }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
