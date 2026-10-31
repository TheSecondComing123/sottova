import Foundation

/// A full set of color tokens for dark and light. Monochrome keeps art as the only color. The others are their
/// authors' real palettes with every accent in play: each section, preset and album gets its own.
struct Palette: Identifiable, Equatable {
    struct Tokens: Equatable {
        var background, raised, hover, border, text, muted, faint, decor: UInt32
        /// The play button's fill, and the ink on it.
        var primary, onPrimary: UInt32
        /// Grounds for covers drawn from type, picked per album, and the ink set on them.
        var covers: [UInt32]
        var coverInk: UInt32
        /// Empty in monochrome, where an item's color falls back to a gray token.
        var accents: [UInt32]
    }

    let id: String
    let name: String
    /// What the two halves are called by their authors, for the picker.
    let detail: String
    let dark: Tokens
    let light: Tokens

    static let all = [monochrome, catppuccin, gruvbox]

    static func named(_ id: String?) -> Palette {
        all.first { $0.id == id } ?? monochrome
    }

    static let monochrome = Palette(
        id: "monochrome", name: "Monochrome", detail: "the art is the only color",
        dark: Tokens(background: 0x0A0A0A, raised: 0x141414, hover: 0x1C1C1C, border: 0x262626,
                     text: 0xF5F5F5, muted: 0xA0A0A0, faint: 0x848484, decor: 0x5C5C5C,
                     primary: 0xF5F5F5, onPrimary: 0x0A0A0A,
                     covers: [0x141414, 0x1A1A1A, 0x202020], coverInk: 0xF5F5F5, accents: []),
        light: Tokens(background: 0xF5F5F5, raised: 0xFFFFFF, hover: 0xEAEAEA, border: 0xE0E0E0,
                      text: 0x0A0A0A, muted: 0x525252, faint: 0x696969, decor: 0xA5A5A5,
                      primary: 0x0A0A0A, onPrimary: 0xF5F5F5,
                      covers: [0xFFFFFF, 0xF0F0F0, 0xE6E6E6], coverInk: 0x0A0A0A, accents: []))

    /// catppuccin.com/palette: Mocha for dark, Latte for light, all fourteen accents. Faint text is a step up from the
    /// palettes' own overlay grays, which fall under 4.5:1 for 11–13 pt type. Latte hovers on crust, not surface0, on
    /// which even its subtext falls under 4.5:1.
    static let catppuccin = Palette(
        id: "catppuccin", name: "Catppuccin", detail: "Mocha in dark, Latte in light",
        dark: Tokens(background: 0x1E1E2E, raised: 0x181825, hover: 0x313244, border: 0x313244,
                     text: 0xCDD6F4, muted: 0xA6ADC8, faint: 0x949AB3, decor: 0x585B70,
                     primary: 0xCBA6F7, onPrimary: 0x11111B,
                     covers: [0x181825], coverInk: 0x11111B, accents: mocha),
        light: Tokens(background: 0xEFF1F5, raised: 0xE6E9EF, hover: 0xDCE0E8, border: 0xCCD0DA,
                      text: 0x4C4F69, muted: 0x5C5F77, faint: 0x5F6278, decor: 0xACB0BE,
                      primary: 0x8839EF, onPrimary: 0xEFF1F5,
                      covers: [0xE6E9EF], coverInk: 0xEFF1F5, accents: latte))

    // rosewater, flamingo, pink, mauve, red, maroon, peach, yellow, green, teal, sky, sapphire, blue, lavender
    private static let mocha: [UInt32] = [0xF5E0DC, 0xF2CDCD, 0xF5C2E7, 0xCBA6F7, 0xF38BA8, 0xEBA0AC, 0xFAB387,
                                          0xF9E2AF, 0xA6E3A1, 0x94E2D5, 0x89DCEB, 0x74C7EC, 0x89B4FA, 0xB4BEFE]
    private static let latte: [UInt32] = [0xDC8A78, 0xDD7878, 0xEA76CB, 0x8839EF, 0xD20F39, 0xE64553, 0xFE640B,
                                          0xDF8E1D, 0x40A02B, 0x179299, 0x04A5E5, 0x209FB5, 0x1E66F5, 0x7287FD]

    /// github.com/morhetz/gruvbox: warm browns and the bright accents in dark, the faded ones in light.
    static let gruvbox = Palette(
        id: "gruvbox", name: "Gruvbox", detail: "warm browns, bright accents",
        dark: Tokens(background: 0x282828, raised: 0x1D2021, hover: 0x3C3836, border: 0x3C3836,
                     text: 0xEBDBB2, muted: 0xBDAE93, faint: 0xAFA089, decor: 0x665C54,
                     primary: 0xFABD2F, onPrimary: 0x1D2021,
                     covers: [0x1D2021], coverInk: 0x1D2021, accents: bright),
        light: Tokens(background: 0xFBF1C7, raised: 0xF9F5D7, hover: 0xEBDBB2, border: 0xD5C4A1,
                      text: 0x3C3836, muted: 0x504945, faint: 0x665C54, decor: 0xBDAE93,
                      primary: 0xB57614, onPrimary: 0xF9F5D7,
                      covers: [0xF9F5D7], coverInk: 0xF9F5D7, accents: faded))

    // red, green, yellow, blue, purple, aqua, orange
    private static let bright: [UInt32] = [0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xFE8019]
    private static let faded: [UInt32] = [0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0xAF3A03]
}
