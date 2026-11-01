import Foundation

/// One side of a theme, as a plain JSON file. Built-ins live in the app's Resources/Themes; files in Application
/// Support/Sottova/Themes are read too, and a file that fails the contrast gate is skipped, with a reason.
public struct ThemeFile: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable { case dark, light }

    public let name: String
    public let side: Side
    public let bg, raised, hover, border, decor, text, muted, faint, primary, onPrimary: String
    public let accents: [String]
    private let sidebar, icon, disabled, popover, coverInk: String?
    private let covers: [String]?

    public var sidebarColor: String { sidebar ?? raised }
    public var iconColor: String { icon ?? faint }
    public var disabledColor: String { disabled ?? decor }
    /// A step up from the window in dark; on light, the window lifted with white.
    public var popoverColor: String { popover ?? (side == .dark ? hover : Self.over("#ffffff", bg, 0.375)) }
    public var coverInkColor: String { coverInk ?? text }
    /// Never empty: a cover drawn from type picks its ground from these by hash.
    public var coverGrounds: [String] { covers.flatMap { $0.isEmpty ? nil : $0 } ?? [raised] }

    /// Why this file can't be used, or nil. Selection is the text color at 10% over the sidebar, as the sidebar draws it.
    public var problem: String? {
        let colors = [bg, raised, hover, border, decor, text, muted, faint, primary, onPrimary, sidebarColor, iconColor,
                      disabledColor, popoverColor, coverInkColor] + accents + coverGrounds
        if let bad = colors.first(where: { Self.rgb($0) == nil }) { return "\(bad) isn't a #rrggbb color" }
        let selection = Self.over(text, sidebarColor, 0.1)
        let checks: [(String, String, String, Double)] = [
            ("text", text, "the background", 4.5), ("text", text, "the sidebar", 4.5), ("text", text, "a selection", 4.5),
            ("muted", muted, "the background", 4.5), ("muted", muted, "the sidebar", 4.5), ("muted", muted, "a selection", 4.5),
            ("faint", faint, "the background", 4.5), ("faint", faint, "the sidebar", 4.5),
            ("primary", primary, "the background", 4.5), ("primary", primary, "a selection", 3),
            ("onPrimary", onPrimary, "primary", 4.5),
        ]
        let grounds = ["the background": bg, "the sidebar": sidebarColor, "a selection": selection, "primary": primary]
        for (name, color, ground, needed) in checks where Self.contrast(color, grounds[ground]!) < needed {
            return "\(name) is too faint on \(ground)"
        }
        return nil
    }

    public struct Rejected: Equatable, Sendable {
        public let file, why: String
    }

    /// Every usable theme in these folders, later folders replacing earlier ones of the same name and side, with
    /// Monochrome always there whatever's on disk.
    public static func load(from folders: [URL]) -> (themes: [ThemeFile], rejected: [Rejected]) {
        var themes = [monochrome(.dark), monochrome(.light)]
        var rejected: [Rejected] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let theme = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(ThemeFile.self, from: $0) }) else {
                    rejected.append(Rejected(file: file.lastPathComponent, why: "it isn't a theme file"))
                    continue
                }
                if let why = theme.problem {
                    rejected.append(Rejected(file: file.lastPathComponent, why: why))
                    continue
                }
                themes.removeAll { $0.name == theme.name && $0.side == theme.side }
                themes.append(theme)
            }
        }
        return (themes, rejected)
    }

    /// What a slot holds: the name chosen for it, else what the old `palette` key meant on that side, else Gruvbox.
    public static func slot(_ side: Side, named name: String?, palette: String?, in themes: [ThemeFile]) -> ThemeFile {
        let fallback: String
        switch palette {
        case "monochrome": fallback = "Monochrome"
        case "catppuccin": fallback = side == .dark ? "Catppuccin Mocha" : "Catppuccin Latte"
        default: fallback = "Gruvbox"
        }
        let onSide = themes.filter { $0.side == side }
        return onSide.first { $0.name == name } ?? onSide.first { $0.name == fallback } ?? monochrome(side)
    }

    /// Compiled in, so no missing or broken file can leave the app without colors.
    public static func monochrome(_ side: Side) -> ThemeFile {
        side == .dark
            ? ThemeFile(name: "Monochrome", side: .dark, bg: "#0a0a0a", raised: "#141414", hover: "#1c1c1c", border: "#262626", decor: "#5c5c5c",
                        text: "#f5f5f5", muted: "#a0a0a0", faint: "#848484", primary: "#f5f5f5", onPrimary: "#0a0a0a", accents: [],
                        sidebar: nil, icon: nil, disabled: nil, popover: nil, coverInk: nil, covers: ["#141414", "#1a1a1a", "#202020"])
            : ThemeFile(name: "Monochrome", side: .light, bg: "#f5f5f5", raised: "#ffffff", hover: "#eaeaea", border: "#e0e0e0", decor: "#a5a5a5",
                        text: "#0a0a0a", muted: "#525252", faint: "#696969", primary: "#0a0a0a", onPrimary: "#f5f5f5", accents: [],
                        sidebar: nil, icon: nil, disabled: nil, popover: nil, coverInk: nil, covers: ["#ffffff", "#f0f0f0", "#e6e6e6"])
    }

    public static func rgb(_ hex: String) -> UInt32? {
        guard hex.count == 7, hex.first == "#" else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func channels(_ hex: String) -> [Double] {
        let value = rgb(hex) ?? 0
        return [16, 8, 0].map { Double(value >> UInt32($0) & 0xFF) / 255 }
    }

    private static func luminance(_ hex: String) -> Double {
        let linear = channels(hex).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func over(_ top: String, _ ground: String, _ alpha: Double) -> String {
        let mixed = zip(channels(top), channels(ground)).map { Int((($1 + ($0 - $1) * alpha) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", mixed[0], mixed[1], mixed[2])
    }
}
