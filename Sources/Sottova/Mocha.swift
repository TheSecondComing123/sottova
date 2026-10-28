import SwiftUI

/// Catppuccin Mocha.
enum Mocha {
    static let base = Color(hex: 0x1E1E2E)
    static let surface1 = Color(hex: 0x45475A)
    static let overlay0 = Color(hex: 0x6C7086)
    static let subtext0 = Color(hex: 0xA6ADC8)
    static let text = Color(hex: 0xCDD6F4)

    static let accents = ([
        0xF5E0DC, 0xF2CDCD, 0xF5C2E7, 0xCBA6F7, 0xF38BA8, 0xEBA0AC, 0xFAB387,
        0xF9E2AF, 0xA6E3A1, 0x94E2D5, 0x89DCEB, 0x74C7EC, 0x89B4FA, 0xB4BEFE,
    ] as [UInt32]).map(Color.init(hex:))

    /// A stable color per track. String.hashValue changes every launch, so this uses FNV-1a.
    static func accent(for name: String?) -> Color {
        guard let name else { return overlay0 }
        let hash = name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        return accents[Int(hash % UInt64(accents.count))]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
