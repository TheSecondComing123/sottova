import Foundation

/// A full set of color tokens for dark and light, from the theme files.
struct Palette: Identifiable, Equatable {
    struct Tokens: Equatable {
        var background, raised, hover, border, text, muted, faint, decor: UInt32
        /// The play button's fill, and the ink on it.
        var primary, onPrimary: UInt32
        /// Grounds for covers drawn from type, picked per album, and the ink set on them.
        var covers: [UInt32]
        var coverInk: UInt32
        /// May be empty: an item's color then falls back to a gray token.
        var accents: [UInt32]
    }

    let id: String
    let name: String
    let detail: String
    let dark: Tokens
    let light: Tokens
}
