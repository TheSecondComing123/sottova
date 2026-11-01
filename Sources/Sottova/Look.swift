#if NEWLOOK
import AppKit
import SwiftUI
import SottovaCore

extension Theme {
    /// What's on disk, re-read at launch and when Settings opens.
    nonisolated(unsafe) private(set) static var themes = ThemeFile.load(from: themeFolders)
    nonisolated(unsafe) private static var slots = currentSlots()

    private static var themeFolders: [URL] {
        var folders = Bundle.main.url(forResource: "Themes", withExtension: nil).map { [$0] } ?? []
        #if SHOT
        folders.append(ShotEnv.storage.appending(path: "Themes"))
        #else
        folders.append(URL.applicationSupportDirectory.appending(path: "Sottova/Themes"))
        #endif
        return folders
    }

    private static func currentSlots() -> (dark: ThemeFile, light: ThemeFile) {
        let defaults = UserDefaults.standard
        let palette = defaults.string(forKey: "palette")
        return (ThemeFile.slot(.dark, named: defaults.string(forKey: "themeDark"), palette: palette, in: themes.themes),
                ThemeFile.slot(.light, named: defaults.string(forKey: "themeLight"), palette: palette, in: themes.themes))
    }

    /// The old tokens follow the slots too, so pages not yet redone sit on the same ground.
    static func slotPalette(_ id: String? = nil) -> Palette {
        if let id { UserDefaults.standard.set(id, forKey: "palette") }
        slots = currentSlots()
        return Palette(id: "\(slots.dark.name)/\(slots.light.name)", name: "", detail: "",
                       dark: Palette.Tokens(slots.dark), light: Palette.Tokens(slots.light))
    }

    static func reloadThemes() {
        themes = ThemeFile.load(from: themeFolders)
        palette = slotPalette()
    }

    static let sidebar = slot(\.sidebarColor)
    static let icon = slot(\.iconColor)
    static let disabled = slot(\.disabledColor)
    static let popover = slot(\.popoverColor)
    static let hairline = text.opacity(0.13)
    static let selection = text.opacity(0.10)
    static let stroke = text.opacity(0.12)
    static let frame = text.opacity(0.20)

    private static func slot(_ path: KeyPath<ThemeFile, String>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let file = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? slots.dark : slots.light
            return rgb(ThemeFile.rgb(file[keyPath: path]) ?? 0)
        })
    }
}

extension Palette.Tokens {
    init(_ file: ThemeFile) {
        let hex = { ThemeFile.rgb($0) ?? 0 }
        self.init(background: hex(file.bg), raised: hex(file.raised), hover: hex(file.hover), border: hex(file.border),
                  text: hex(file.text), muted: hex(file.muted), faint: hex(file.faint), decor: hex(file.decor),
                  primary: hex(file.primary), onPrimary: hex(file.onPrimary),
                  covers: file.coverGrounds.map(hex), coverInk: hex(file.coverInkColor), accents: file.accents.map(hex))
    }
}

/// The type scale, from v4.css.
enum Role {
    case title, name, row, sheet, body, small, label

    var size: CGFloat {
        switch self {
        case .title: 32
        case .name: 22
        case .row: 17
        case .sheet: 15
        case .body: 13
        case .small: 12
        case .label: 11
        }
    }

    var line: CGFloat {
        switch self {
        case .title: 37
        case .name: 27
        case .row: 22
        case .sheet: 20
        case .body: 18
        case .small: 16
        case .label: 14
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title, .name, .row: .medium
        case .sheet, .label: .semibold
        case .body, .small: .regular
        }
    }

    var font: Font { .system(size: size, weight: weight) }
}

enum Radius {
    static let small: CGFloat = 6, medium: CGFloat = 8, large: CGFloat = 10, window: CGFloat = 12
}

extension View {
    func role(_ role: Role) -> some View {
        font(role.font)
            .lineHeight(.exact(points: role.line))
            // -.011em, on the title only
            .kerning(role == .title ? -0.352 : 0)
    }
}

/// `.btn` in the mock: quiet by default; `primary` is the single next action.
struct ThemeButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .role(.body)
                .foregroundStyle(primary ? Theme.onPrimary : Theme.text)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(primary ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.selection), in: .rect(cornerRadius: Radius.small))
                .overlay {
                    if !primary { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
                }
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}

/// `.h` in the mock: a sidebar or page section's name, with room for an action at its right.
struct SectionHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Text(title).role(.label).foregroundStyle(Theme.faint).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: 14)
        .padding(.horizontal, 8)
    }
}

/// `.lnk` in the mock, the accent on the one thing to do next; with `underlined`, `.u`: running text you can click.
struct ThemeLink: View {
    let text: String
    var underlined = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .underline(underlined, color: Theme.faint)
                .foregroundStyle(underlined ? Theme.text : Theme.primary)
        }
        .buttonStyle(.plain)
    }
}

/// 14 pt box from the mock, in the theme's color rather than the system's accent; VoiceOver gets the real toggle.
struct ThemeCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.selection))
                    .overlay { if !configuration.isOn { RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.frame, lineWidth: 0.5) } }
                    .overlay { if configuration.isOn { Ph.check.icon(.bold, size: 10).foregroundStyle(Theme.background) } }
                    .frame(width: 14, height: 14)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
#endif
