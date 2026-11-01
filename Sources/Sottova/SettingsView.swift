import EventKit
import ServiceManagement
import SwiftUI
import SottovaCore

#if !NEWLOOK
/// Settings in the main window's language: a rail of three pages, and on each a control shaped like what it sets.
struct SettingsView: View {
    @Bindable var controller: Controller
    @State private var page = Page.playback
    @AppStorage("palette") private var palette = Palette.monochrome.id

    enum Page: String, CaseIterable {
        case playback = "Playback", library = "Library", theme = "Theme", general = "General"

        var icon: Ph {
            switch self {
            case .playback: .waveform
            case .library: .folder
            case .theme: .palette
            case .general: .gearSix
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, item in
                    Button { page = item } label: {
                        HStack(spacing: 12) {
                            item.icon.icon(size: 18)
                                .foregroundStyle(Theme.accent(index * 3 + 1, or: page == item ? \.text : \.muted))
                                .frame(width: 20)
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(page == item ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Theme.hover.opacity(page == item ? 1 : 0), in: .rect(cornerRadius: 8))
                        .hoverable(radius: 8)
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            // clears the traffic lights, which sit over the rail
            .padding(.top, 48)
            .frame(width: 200)

            Rectangle().fill(Theme.border).frame(width: 1)

            ScrollView {
                Group {
                    switch page {
                    case .playback: PlaybackPage(controller: controller)
                    case .library: LibraryPage(controller: controller)
                    case .theme: ThemePage(selection: $palette)
                    case .general: GeneralPage(controller: controller)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        // 560 tall below the hidden title bar, then stretched up under it so the rail meets the traffic lights
        // re-keyed on the palette so it redraws in the new colors; the page lives above, so it stays put
        .id(palette)
        .frame(width: 760)
        .frame(minHeight: 560, idealHeight: 560, maxHeight: .infinity)
        .background(Theme.background)
        .ignoresSafeArea()
    }
}
#endif

private struct PageTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.bottom, 24)
    }
}

/// A heading over a group of controls, with an optional value on the right in the same line.
private struct Heading: View {
    let title: String
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 12)
    }
}

// MARK: - Playback

private struct PlaybackPage: View {
    @Bindable var controller: Controller

    var body: some View {
        let s = controller.settings
        VStack(alignment: .leading, spacing: 0) {
            // the diagram is the summary; a line restating it would be the fourth "10–20 min" on screen
            PageTitle(title: "Playback")
            ScoreDiagram(settings: s)

            Heading(title: "Preset")
            // three to a row: five in one squeezed the names into two lines
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(controller.allPresets, id: \.name) { preset in
                    PresetCard(preset: preset, active: s.name == preset.name,
                           accent: 2 + 4 * (controller.allPresets.firstIndex { $0.name == preset.name } ?? 0)) { controller.apply(preset) }
                }
            }

            if !s.crossfade {
                Heading(title: "Silence between songs", value: Format.range(s))
                GapRange(low: $controller.settings.gapMin, high: $controller.settings.gapMax)
            }

            Heading(title: "Fades")
            HStack(spacing: 12) {
                // each in its half, so Out sits over the second curve card below
                ValueStepper(label: "In", value: $controller.settings.fadeIn, range: 0...20, unit: "s")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ValueStepper(label: "Out", value: $controller.settings.fadeOut, range: 0...20, unit: "s")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                CurveCard(curve: .quartic, title: "Quartic", detail: "quiet for longer, then rises", selected: s.curve == .quartic, accent: 1) {
                    controller.settings.curve = .quartic
                }
                CurveCard(curve: .dbLinear, title: "Even", detail: "loudness rises at a steady rate", selected: s.curve == .dbLinear, accent: 5) {
                    controller.settings.curve = .dbLinear
                }
            }
            .padding(.top, 12)

            Heading(title: "Overlap")
            SwitchRow(title: "Crossfade instead of silence", detail: "songs overlap with no silence between them", isOn: $controller.settings.crossfade)
            if s.crossfade {
                ValueStepper(label: "Crossfade", value: $controller.settings.crossfadeSec, range: 1...10, unit: "s")
                    .padding(.top, 12)
            }

            Heading(title: "Loudness", value: "\(Int(s.targetLufs)) LUFS".replacingOccurrences(of: "-", with: "−"))
            HStack(spacing: 12) {
                ForEach(Array([(-14.0, "Loud", "like streaming apps"), (-18, "Medium", "the default"), (-23, "Quiet", "like broadcast tv")].enumerated()),
                        id: \.offset) { index, level in
                    LoudnessCard(lufs: level.0, title: level.1, detail: level.2, selected: s.targetLufs == level.0, accent: 3 + 4 * index) {
                        controller.settings.targetLufs = level.0
                    }
                }
            }
            Text("starts with the next song")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.faint)
                .padding(.top, 8)

            Heading(title: "Shuffle")
            HStack(spacing: 16) {
                Text("Don't repeat any of the last")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                ValueStepper(value: Binding(get: { Double(controller.settings.avoidLastN) }, set: { controller.settings.avoidLastN = Int($0) }),
                             range: 0...50, unit: "songs")
            }
        }
        .animation(Theme.quick, value: s.crossfade)
    }
}

/// What the settings sound like, drawn: a track fading out, the silence, the next fading in. Not to scale: the gap is
/// minutes and the fades are seconds, so each gets a fixed part of the width and carries its own number.
struct ScoreDiagram: View {
    let settings: SottovaCore.Settings
    var height: CGFloat = 140

    var body: some View {
        Canvas { gc, size in
            let base = size.height - 28
            let top: CGFloat = 20
            let h = base - top
            gc.fill(Path(CGRect(x: 16, y: base, width: size.width - 32, height: 1)), with: .color(Theme.border))

            func ramp(from x0: CGFloat, to x1: CGFloat, rising: Bool) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: base))
                for x in stride(from: x0, through: x1, by: 1) {
                    let t = Double((x - x0) / max(x1 - x0, 1))
                    let gain = rising ? settings.curve.fadeIn(t) : settings.curve.fadeOut(t)
                    p.addLine(to: CGPoint(x: x, y: base - CGFloat(gain) * h))
                }
                p.addLine(to: CGPoint(x: x1, y: base))
                p.closeSubpath()
                return p
            }
            func label(_ text: String, at x: CGFloat) {
                gc.draw(Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted),
                        at: CGPoint(x: x, y: base + 8), anchor: .top)
            }

            let w = size.width
            if settings.crossfade {
                let x0 = w * 0.3, x1 = w * 0.7
                gc.fill(Path(CGRect(x: 16, y: top, width: x0 - 16, height: h)), with: .color(Theme.text.opacity(0.18)))
                gc.fill(ramp(from: x0, to: x1, rising: false), with: .color(Theme.text.opacity(0.18)))
                gc.fill(ramp(from: x0, to: x1, rising: true), with: .color(Theme.text))
                gc.fill(Path(CGRect(x: x1, y: top, width: w - 16 - x1, height: h)), with: .color(Theme.text))
                label("\(Int(settings.crossfadeSec)) s overlap", at: (x0 + x1) / 2)
                return
            }
            let outStart = w * 0.12, outEnd = w * 0.3, inStart = w * 0.7, inEnd = w * 0.88
            gc.fill(Path(CGRect(x: 16, y: top, width: outStart - 16, height: h)), with: .color(Theme.text.opacity(0.18)))
            gc.fill(ramp(from: outStart, to: outEnd, rising: false), with: .color(Theme.text.opacity(0.18)))
            gc.fill(ramp(from: inStart, to: inEnd, rising: true), with: .color(Theme.text))
            gc.fill(Path(CGRect(x: inEnd, y: top, width: w - 16 - inEnd, height: h)), with: .color(Theme.text))
            var x = outEnd + 10
            while x < inStart - 8 {
                gc.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: base - 1.5, width: 3, height: 3)), with: .color(Theme.muted))
                x += 10
            }
            label("\(Int(settings.fadeOut)) s out", at: (outStart + outEnd) / 2)
            label(Format.range(settings), at: w / 2)
            label("\(Int(settings.fadeIn)) s in", at: (inStart + inEnd) / 2)
        }
        .frame(height: height)
        .background(Theme.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .animation(Theme.quick, value: settings)
        .accessibilityLabel("\(Format.gaps(settings)), \(Int(settings.fadeIn)) second fade in, \(Int(settings.fadeOut)) second fade out")
    }
}

struct PresetCard: View {
    let preset: SottovaCore.Settings
    let active: Bool
    /// nil draws the active border in the text color.
    let accent: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(preset.crossfade ? "overlapping" : Format.range(preset))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .foregroundStyle(active ? Theme.text : Theme.faint)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? accent.map { Theme.accent($0) } ?? Theme.text : Theme.border, lineWidth: active ? 1.5 : 1))
            .hoverable(radius: 12)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(Theme.quick, value: active)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The shortest and longest gap on one track, on a log scale so 2 s and 20 min both get room. Snaps to a second
/// below 30 s and to 30 s above.
struct GapRange: View {
    @Binding var low: Double
    @Binding var high: Double
    private let maximum = 1200.0
    private let ticks: [(Double, String)] = [(0, "0"), (10, "10 s"), (30, "30 s"), (120, "2 min"), (300, "5 min"), (600, "10 min"), (1200, "20 min")]

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let x0 = position(low) * w, x1 = position(high) * w
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.text).frame(width: max(x1 - x0, 4), height: 4).offset(x: x0)
                    thumb.offset(x: x0 - 8)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { low = min(seconds(at: $0.location.x / w), high) })
                        .help("drag to set the shortest gap")
                    thumb.offset(x: x1 - 8)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { high = max(seconds(at: $0.location.x / w), low) })
                        .help("drag to set the longest gap")
                }
                .frame(height: 20)
            }
            .frame(height: 20)
            GeometryReader { geo in
                ForEach(ticks, id: \.0) { value, name in
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .fixedSize()
                        .position(x: position(value) * geo.size.width, y: 6)
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 8)
        .accessibilityRepresentation {
            Slider(value: $low, in: 0...maximum, step: 1) { Text("Shortest gap") }
            Slider(value: $high, in: 0...maximum, step: 1) { Text("Longest gap") }
        }
    }

    private var thumb: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.text)
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.background, lineWidth: 2))
    }

    /// 0 at the left, 20 min at the right, with the first minutes spread out: 2 min sits near the middle.
    private func position(_ seconds: Double) -> CGFloat {
        CGFloat(log(1 + 100 * seconds / maximum) / log(101))
    }

    private func seconds(at position: CGFloat) -> Double {
        let p = Double(min(max(position, 0), 1))
        let s = (pow(101, p) - 1) / 100 * maximum
        return s < 30 ? s.rounded() : (s / 30).rounded() * 30
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

/// A fade curve you pick by its shape.
private struct CurveCard: View {
    let curve: FadeCurve
    let title: String
    let detail: String
    let selected: Bool
    /// Marks it selected the way Mode and Loudness mark theirs; monochrome falls back to the text color.
    let accent: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Canvas { gc, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for x in stride(from: 0, through: size.width, by: 1) {
                        p.addLine(to: CGPoint(x: x, y: size.height - CGFloat(curve.fadeIn(Double(x / size.width))) * size.height))
                    }
                    gc.stroke(p, with: .color(selected ? Theme.accent(accent) : Theme.muted), lineWidth: 1.5)
                }
                .frame(width: 44, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent(accent) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .hoverable(radius: 12)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(Theme.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A loudness to level every piece to, drawn as how tall a waveform stands at it: −14 is 2.8 times −23.
private struct LoudnessCard: View {
    let lufs: Double
    let title: String
    let detail: String
    let selected: Bool
    let accent: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Canvas { gc, size in
                    let amplitude = pow(10, (lufs + 14) / 20)
                    let shape: [Double] = [0.35, 0.7, 1, 0.55, 0.85, 0.45, 0.75, 0.3]
                    for (i, h) in shape.enumerated() {
                        let height = size.height * amplitude * h
                        let x = CGFloat(i) * size.width / CGFloat(shape.count)
                        gc.fill(Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2, width: 2.5, height: height), cornerRadius: 1),
                                with: .color(selected ? Theme.accent(accent) : Theme.muted))
                    }
                }
                .frame(width: 64, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        Text("\(Int(lufs))".replacingOccurrences(of: "-", with: "−"))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                    }
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent(accent) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .hoverable(radius: 12)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(Theme.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A title and why, with a switch on the right. The whole row toggles.
private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SquareSwitch())
    }
}

/// A switch with square shoulders: the knob slides on a spring, filled when on.
private struct SquareSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 0)
                SwitchKnob(on: configuration.isOn)
            }
            .padding(12)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The switch itself, square like the rest of the app, without a card around it.
struct SwitchKnob: View {
    let on: Bool

    var body: some View {
        #if NEWLOOK
        // the new look's checkbox, for what's left on this name until the switch
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: 3.5).fill(Theme.muted)
                Ph.check.icon(.bold, size: 10).foregroundStyle(Theme.background)
            } else {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.frame, lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
        #else
        ZStack(alignment: on ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(on ? Theme.text : Theme.hover)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Theme.background : Theme.muted)
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .frame(width: 40, height: 22)
        .animation(Theme.settle, value: on)
        #endif
    }
}

// MARK: - Theme

private struct ThemePage: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Theme", detail: "light or dark still follows the system")
            // a plain grid, not a lazy one: lazy cells arrive a pass after the page, so it showed up empty first
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(Array(stride(from: 0, to: Palette.all.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(Palette.all[start..<min(start + 2, Palette.all.count)]) { palette in
                            PaletteCard(palette: palette, selected: selection == palette.id) {
                                // set before the stored id changes, so the re-keyed views draw in the new palette
                                Theme.select(palette.id)
                                selection = palette.id
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A palette shown as a tiny window in its own colors: sidebar, a shelf of covers, a title, the play button.
private struct PaletteCard: View {
    let palette: Palette
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = scheme == .dark ? palette.dark : palette.light
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Canvas { gc, size in
                    let c = { (hex: UInt32) in Color(nsColor: Theme.rgb(hex)) }
                    gc.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(c(t.background)))
                    gc.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * 0.26, height: size.height), cornerRadius: 8), with: .color(c(t.raised)))
                    for row in 0..<4 {
                        let w = size.width * (row == 1 ? 0.14 : 0.18)
                        gc.fill(Path(roundedRect: CGRect(x: 10, y: 14 + CGFloat(row) * 14, width: w, height: 5), cornerRadius: 2),
                                with: .color(c(row == 1 ? t.text : t.muted)))
                    }
                    let x0 = size.width * 0.32
                    gc.fill(Path(roundedRect: CGRect(x: x0, y: 14, width: size.width * 0.34, height: 9), cornerRadius: 2), with: .color(c(t.text)))
                    gc.fill(Path(roundedRect: CGRect(x: x0, y: 29, width: size.width * 0.22, height: 5), cornerRadius: 2), with: .color(c(t.muted)))
                    let side = (size.width - x0 - 12 - 3 * 8) / 4
                    let grounds = t.accents.isEmpty ? t.covers : t.accents
                    for i in 0..<4 {
                        let rect = CGRect(x: x0 + CGFloat(i) * (side + 8), y: 46, width: side, height: side)
                        gc.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(c(grounds[(i * 3 + 1) % grounds.count])))
                        gc.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(c(t.border)), lineWidth: 1)
                    }
                    gc.fill(Path(ellipseIn: CGRect(x: size.width - 34, y: size.height - 30, width: 22, height: 22)), with: .color(c(t.primary)))
                }
                .frame(height: 120)
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(palette.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(12)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.text : Theme.border, lineWidth: selected ? 1.5 : 1))
            .hoverable(radius: 12)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Library

private struct LibraryPage: View {
    let controller: Controller
    @State private var showsSkipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Library", detail: controller.libraryLine)

            VStack(spacing: 8) {
                ForEach(controller.folders, id: \.self) { folder in
                    FolderRow(folder: folder, songs: songCount(in: folder)) { controller.removeFolder(folder) }
                }
            }

            HStack(spacing: 12) {
                Button("Add a music folder", action: controller.chooseFolders)
                    .buttonStyle(InvertedButton())
                Button(action: controller.rescan) {
                    HStack(spacing: 8) {
                        Ph.arrowsClockwise.icon(size: 16)
                        Text("Rescan")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .hoverable(radius: 8)
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .help("look through the folders again now, instead of waiting for a change")
            }
            .padding(.top, 16)

            if !controller.skippedFiles.isEmpty {
                Heading(title: "Can't be played", value: Format.count(controller.skippedFiles.count, "file"))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.skippedFiles.prefix(showsSkipped ? .max : 5), id: \.self) { file in
                        Text(file.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    if controller.skippedFiles.count > 5 {
                        LinkText(text: showsSkipped ? "Show fewer" : "Show all \(controller.skippedFiles.count)") { showsSkipped.toggle() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func songCount(in folder: URL) -> Int {
        let prefix = folder.path(percentEncoded: false)
        return controller.tracks.count { $0.path(percentEncoded: false).hasPrefix(prefix) }
    }
}

private struct FolderRow: View {
    let folder: URL
    let songs: Int
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Ph.folder.icon(size: 20)
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(folder.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 16)
            Text(Format.count(songs, "song"))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Button(action: remove) {
                Ph.x.icon(.bold, size: 12)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .hoverable(radius: 8)
            }
            .buttonStyle(PressStyle())
            .opacity(hovering ? 1 : 0)
            .help("stop watching this folder; the files stay where they are")
            .accessibilityLabel("Remove \(folder.lastPathComponent)")
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Theme.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @Bindable var controller: Controller
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageTitle(title: "General")
            SwitchRow(title: "Open at login", detail: "starts in the menu bar when you log in", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
            if let loginProblem {
                Text(loginProblem)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
            }
            SwitchRow(title: "Keep the mac awake during gaps",
                      detail: "sound stops between songs, so without this the mac can go to sleep in the middle of a silence",
                      isOn: $controller.keepsMacAwake)
            SwitchRow(title: "Accept sottova:// links",
                      detail: "play, pause, toggle, skip and preset/minecraft, from Raycast, Shortcuts or a script. status.json in Application Support/Sottova follows every change.",
                      isOn: $controller.acceptsURLs)
            CalendarChoices()
        }
        .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginProblem = nil
        } catch {
            loginProblem = "couldn't change login items: \(error.localizedDescription)"
        }
        // the user can also change this in System Settings, so read back what actually happened
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Which calendars count for a row on Your day set to mind them.
private struct CalendarChoices: View {
    @State private var status = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [EKCalendar] = []
    @State private var counted: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(title: "Calendar")
            Text("anything on your day set to \"not while my calendar is busy\" waits, or skips the day, while one of these has something on")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            switch status {
            case .fullAccess:
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    SwitchRow(title: calendar.title, detail: calendar.source.title, isOn: Binding(
                        get: { counted[calendar.calendarIdentifier] ?? Presence.counts(calendar) },
                        set: { on in
                            Presence.setCounts(on, for: calendar)
                            counted[calendar.calendarIdentifier] = on
                        }))
                }
            case .notDetermined:
                Button("Allow access to calendars") {
                    Task {
                        await Presence.askForCalendars()
                        refresh()
                    }
                }
                .buttonStyle(InvertedButton())
            default:
                HStack(spacing: 8) {
                    Text("sottova can't see your calendars")
                    LinkText(text: "allow it in System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    .foregroundStyle(Theme.text)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        calendars = Presence.calendars
    }
}

struct PresetPicker: View {
    let controller: Controller

    var body: some View {
        Picker("preset", selection: Binding(
            get: { controller.settings.name },
            set: { name in
                if let preset = controller.allPresets.first(where: { $0.name == name }) {
                    controller.apply(preset)
                }
            }
        )) {
            ForEach(controller.allPresets, id: \.name) { preset in
                Text(preset.name).tag(preset.name)
            }
            if controller.settings.name == "Custom" {
                Text("Custom").tag("Custom")
            }
        }
    }
}

/// A preset to make, or the one it changes.
struct PresetEdit: Identifiable {
    let id = UUID()
    var preset: SottovaCore.Settings
    var replacing: String?
    #if NEWLOOK
    /// Silence for one collection rather than a preset: its name, and where it goes.
    var collection: (name: String, apply: (SottovaCore.Settings) -> Void)?
    #endif
}

/// Names a preset and sets its gaps and fades; the rest of how it plays comes from where it started.
struct PresetSheet: View {
    let edit: PresetEdit
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SottovaCore.Settings
    @FocusState private var typing: Bool

    init(edit: PresetEdit) {
        self.edit = edit
        _draft = State(initialValue: edit.preset)
    }

    private var blank: Bool { draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Name this preset", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .focused($typing)
                .onChange(of: typing) { _, focused in router.typing = focused }
                .padding(.bottom, 16)

            ScoreDiagram(settings: draft, height: 112)

            if !draft.crossfade {
                caption("Silence between songs")
                GapRange(low: $draft.gapMin, high: $draft.gapMax)
                    .padding(.horizontal, 12)
            }
            caption("Fades")
            HStack(spacing: 12) {
                ValueStepper(label: "In", value: $draft.fadeIn, range: 0...20, unit: "s")
                ValueStepper(label: "Out", value: $draft.fadeOut, range: 0...20, unit: "s")
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(QuietButton())
                Button("Save") {
                    controller.savePreset(draft, replacing: edit.replacing)
                    dismiss()
                }
                .buttonStyle(InvertedButton())
                .keyboardShortcut(.defaultAction)
                .disabled(blank)
            }
            .padding(.top, 24)
        }
        .padding(24)
        .frame(width: 420)
        .presentationBackground(Theme.raised)
        .onAppear { typing = true }
        .onDisappear { router.typing = false }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}
