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
    static let stroke = text.opacity(0.12)
    static let frame = text.opacity(0.20)
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
        case .item, .sheet: 15
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
        case .item, .sheet: 20
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { icon.icon(iconWeight, size: 11) }
                Text(title).role(.body)
            }
                .foregroundStyle(primary ? Theme.onPrimary : on ? Theme.primary : Theme.text)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(primary ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.selection), in: .rect(cornerRadius: Radius.small))
                .overlay {
                    if !primary { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(on ? Theme.primary : Theme.stroke, lineWidth: on ? 1 : 0.5) }
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
    var color: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .underline(underlined, color: Theme.faint)
                .foregroundStyle(color ?? (underlined ? Theme.text : Theme.primary))
        }
        .buttonStyle(.plain)
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
                if focused { RoundedRectangle(cornerRadius: Radius.small).stroke(Theme.primary.opacity(0.55), lineWidth: 2.5).padding(-1.25) }
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

/// `.btn.def` as a style, for buttons with their own label and shortcut.
struct PrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .role(.body)
            .foregroundStyle(enabled ? Theme.onPrimary : Theme.disabled)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(enabled ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.selection), in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// `.btn` as a style.
struct SecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .role(.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Theme.selection, in: .rect(cornerRadius: Radius.small))
            .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// − value + in one bordered strip, for whole numbers.
struct ValueStepper: View {
    var label: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var step: Double = 1

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
            Text("\(Int(value)) \(unit)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 64)
                .contentTransition(.numericText(value: value))
            step(.plus, by: step)
        }
        .frame(height: 32)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .accessibilityRepresentation {
            Stepper("\(label ?? "") \(Int(value)) \(unit)", value: $value, in: range, step: step)
        }
    }

    private func step(_ icon: Ph, by delta: Double) -> some View {
        Button {
            withAnimation(Theme.quick) { value = min(max(value + delta, range.lowerBound), range.upperBound) }
        } label: {
            icon.icon(.bold, size: 12)
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .hoverable(radius: 8)
        }
        .buttonRepeatBehavior(.enabled)
        .buttonStyle(PressStyle())
        .disabled(delta < 0 ? value <= range.lowerBound : value >= range.upperBound)
    }
}
