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

    /// Theme's tokens follow the slots.
    static func slotPalette() -> Palette {
        slots = currentSlots()
        return Palette(id: "\(slots.dark.name)/\(slots.light.name)", name: "", detail: "",
                       dark: Palette.Tokens(slots.dark), light: Palette.Tokens(slots.light))
    }

    static var slotNames: (dark: String, light: String) { (slots.dark.name, slots.light.name) }

    /// True when the colors changed, so the scenes know to re-key.
    static func reloadThemes() -> Bool {
        themes = ThemeFile.load(from: themeFolders)
        let before = palette
        palette = slotPalette()
        return palette != before
    }

    static let sidebar = slot(\.sidebarColor)
    static let icon = slot(\.iconColor)
    static let disabled = slot(\.disabledColor)
    static let popover = slot(\.popoverColor)
    static let hairline = text.opacity(0.13)
    static let selection = text.opacity(0.16)
    /// A picked row: the accent, quiet, so it never reads as the gray of a hovered one.
    static let picked = primary.opacity(0.24)
    /// A quiet button under the pointer.
    static let buttonHover = text.opacity(0.24)
    static let stroke = text.opacity(0.12)
    static let frame = text.opacity(0.20)
    /// The ring on a field that has the keys, from `.focus` in the mock.
    static let focus = primary.opacity(0.55)
    /// The outline that keeps a painting's edge on any ground.
    static let artEdge = Color(white: 0.5, opacity: 0.28)
    static let knob = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(text) : .white
    })

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
    case title, name, row, item, sheet, body, small, label, column

    var size: CGFloat {
        switch self {
        case .title: 32
        case .name: 22
        case .row: 17
        case .sheet: 17
        case .item: 15
        case .body: 13
        case .small: 12
        case .label, .column: 11
        }
    }

    var line: CGFloat {
        switch self {
        case .title: 37
        case .name: 27
        case .row: 22
        case .sheet: 21
        case .item: 20
        case .body: 18
        case .small: 16
        case .label, .column: 14
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title, .name, .row, .item, .column: .medium
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
    /// A mode that's in effect, such as shuffling: drawn in the accent.
    var on = false
    var icon: Ph?
    var iconWeight = Ph.IconWeight.fill
    let action: () -> Void
    /// `.large` beside a large title, as on Now.
    @Environment(\.controlSize) private var size

    var body: some View {
        let large = size == .large
        Button(action: action) {
            HStack(spacing: large ? 7 : 6) {
                if let icon { icon.icon(iconWeight, size: large ? 13 : 11) }
                Text(title)
            }
        }
        .buttonStyle(ThemeButtonStyle(primary: primary, on: on))
    }
}

/// ThemeButton's look, for a button with its own label, role and shortcut, as a sheet's are.
struct ThemeButtonStyle: ButtonStyle {
    var primary = false
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        Drawn(label: configuration.label, primary: primary, on: on)
            .modifier(Press(pressed: configuration.isPressed, scale: 0.98))
    }

    /// A style can't hold the hover; a view can.
    private struct Drawn<Label: View>: View {
        let label: Label
        let primary: Bool
        let on: Bool
        @State private var hovering = false
        @Environment(\.controlSize) private var size

        var body: some View {
            let large = size == .large
            label
                .role(large ? .item : .body)
                .foregroundStyle(primary ? Theme.onPrimary : on ? Theme.primary : Theme.text)
                .padding(.horizontal, large ? 14 : 11)
                .frame(height: large ? 30 : 24)
                .background(primary ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(hovering ? Theme.buttonHover : Theme.selection), in: .rect(cornerRadius: Radius.small))
                .brightness(primary && hovering ? 0.06 : 0)
                .overlay {
                    if !primary { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(on ? Theme.primary : Theme.stroke, lineWidth: on ? 1 : 0.5) }
                }
                .animation(Theme.reveal(hovering), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// ••• : the rest of what something does, behind a native menu, with IconButton's round plate.
struct MoreMenu<Content: View>: View {
    var label = "more"
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Ph.dotsThree.icon(size: 14)
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .hoverable(radius: 12)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("more")
        .accessibilityLabel(label)
    }
}

/// Clickable text. `.action`, `.lnk` in the mock: a verb on its own, such as the accent on the one thing to do next.
/// `.inline`, `.u`: running text you can click.
struct ThemeLink: View {
    enum Style { case action, inline }

    let text: String
    var style = Style.action
    var color: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // a button rather than a tap gesture, so VoiceOver can follow the link
        Button(action: action) {
            Text(text)
                .linkUnderline(inline: style == .inline, hovering: hovering)
                .foregroundStyle(color ?? (style == .inline ? Theme.text : Theme.primary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

extension Text {
    /// How text says it's clickable: in running text, always and faintly; on its own, under the pointer.
    func linkUnderline(inline: Bool = false, hovering: Bool = false) -> Text {
        inline ? underline(color: Theme.faint) : underline(hovering)
    }
}

/// `.field` in the mock, its ring from `.focus`.
struct FieldLook: ViewModifier {
    var focused = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .frame(height: 24)
            // the mock's .18 is for dark grounds; on a light one it reads as disabled
            .background(.black.opacity(scheme == .dark ? 0.18 : 0.05), in: .rect(cornerRadius: Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.frame, lineWidth: 0.5)
                if focused { RoundedRectangle(cornerRadius: Radius.small).stroke(Theme.focus, lineWidth: 2.5).padding(-1.25) }
            }
    }
}

extension View {
    /// The ground of a search field: the Songs filter, the cover search and Add songs. `shown` is false for a field
    /// that shows itself only under the pointer; `focused` rings it, for a field that doesn't draw its own ring.
    func fieldGround(focused: Bool = false, shown: Bool = true) -> some View {
        frame(height: 28)
            .background(Theme.raised.opacity(shown ? 1 : 0), in: .rect(cornerRadius: Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.frame, lineWidth: 0.5).opacity(shown ? 1 : 0)
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.focus, lineWidth: 1).opacity(focused ? 1 : 0)
            }
    }
}

/// `.popup` in the mock: a native menu behind the theme's button.
struct ThemePopup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title).role(.body).foregroundStyle(Theme.text)
                Ph.caretUpDown.icon(.line, size: 11).foregroundStyle(Theme.muted)
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(Theme.selection, in: .rect(cornerRadius: Radius.small))
            .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A label with a 14 pt box at the row's right, from the mock, in the theme's color rather than the system's accent; VoiceOver gets the real toggle.
struct ThemeCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 0)
                CheckBox(on: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// `.check`'s box, from the mock.
struct CheckBox: View {
    let on: Bool

    var body: some View {
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: 3.5).fill(Theme.muted)
                Ph.check.icon(.bold, size: 10).foregroundStyle(Theme.background)
            } else {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.frame, lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// − value + in one bordered strip; `format` writes the value, for the eye and for VoiceOver.
struct ValueStepper: View {
    var label: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    /// The tooltips on − and +.
    var help = (less: "", more: "")

    var body: some View {
        HStack(spacing: 0) {
            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
            }
            step(.minus, by: -step)
            Text(format(value))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 64)
                .contentTransition(.numericText(value: value))
                // only the number: a held + on a trim would leave the waveform's handles trailing behind
                .animation(Theme.quick, value: value)
            step(.plus, by: step)
        }
        .frame(height: 32)
        .background(Theme.raised, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Theme.border))
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { Text(label ?? "") }
                .accessibilityValue(format(value))
        }
    }

    private func step(_ icon: Ph, by delta: Double) -> some View {
        Button {
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            icon.icon(.bold, size: 12)
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .hoverable(radius: Radius.medium)
        }
        .buttonRepeatBehavior(.enabled)
        .buttonStyle(PressStyle())
        .disabled(delta < 0 ? value <= range.lowerBound : value >= range.upperBound)
        .help(delta < 0 ? help.less : help.more)
    }
}
