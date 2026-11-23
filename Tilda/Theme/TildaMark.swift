import SwiftUI

/// The Tilda logo: a dotted tilde (a LiDAR point cloud tracing "~") on a dark tile.
/// `cornerRatio` is the tile corner radius as a fraction of its side; use 0 for a full-bleed app icon.
struct TildaMark: View {
    var cornerRatio: CGFloat = 0.225

    private static let waveDots = 10
    private static let scatter: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (0.22, 0.34, 0.012), (0.42, 0.30, 0.009), (0.64, 0.68, 0.011),
        (0.80, 0.34, 0.008), (0.32, 0.68, 0.009), (0.56, 0.36, 0.007),
    ]

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let teal = Color(red: 0x5D/255, green: 0xCA/255, blue: 0xA5/255)
            let tile = Color(red: 0x0B/255, green: 0x1F/255, blue: 0x1A/255)
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: s * cornerRatio, style: .continuous), with: .color(tile))

            for d in Self.scatter {
                let r = d.r * s
                ctx.fill(Path(ellipseIn: CGRect(x: d.x * s - r, y: d.y * s - r, width: r * 2, height: r * 2)),
                         with: .color(teal.opacity(0.28)))
            }
            let n = Self.waveDots
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n - 1)
                let x = (0.13 + 0.74 * t) * s
                let y = (0.5 - 0.14 * sin(2 * .pi * t)) * s
                let r = (0.017 + 0.027 * sin(.pi * t)) * s
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(teal))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview { TildaMark().frame(width: 200) }
