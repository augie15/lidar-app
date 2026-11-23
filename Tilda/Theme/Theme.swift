import SwiftUI

/// Tilda design tokens. Dark-only; near-black green with a single teal accent.
enum Theme {
    static let background = Color(red: 0x0E/255, green: 0x14/255, blue: 0x12/255)
    static let card = Color(red: 0x1C/255, green: 0x24/255, blue: 0x21/255)
    static let featured = Color(red: 0x16/255, green: 0x3A/255, blue: 0x30/255)
    static let tile = Color(red: 0x0B/255, green: 0x1F/255, blue: 0x1A/255)
    static let accent = Color(red: 0x5D/255, green: 0xCA/255, blue: 0xA5/255)
    static let accentText = Color(red: 0x9F/255, green: 0xE1/255, blue: 0xCB/255)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color(red: 0xB4/255, green: 0xB2/255, blue: 0xA9/255)
    static let textMuted = Color(red: 0x88/255, green: 0x87/255, blue: 0x80/255)
    static let separator = Color.white.opacity(0.08)

    static let radiusCard: CGFloat = 22
    static let radiusSmall: CGFloat = 14
}

extension ScanKind {
    var symbol: String {
        switch self {
        case .room: "square.split.bottomrightquarter"
        case .object: "cube"
        case .mesh: "triangle"
        }
    }

    var tagline: String {
        switch self {
        case .room: "Walls, doors and furniture"
        case .object: "Photoreal"
        case .mesh: "Raw LiDAR"
        }
    }
}
