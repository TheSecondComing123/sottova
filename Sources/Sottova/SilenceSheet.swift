#if NEWLOOK
import SwiftUI
import SottovaCore

/// Makes or changes a preset, with the lengths typed: "5 min", "90 s". The fade out and the rest of how it plays come
/// from where it started.
struct SilenceSheet: View {
    let edit: PresetEdit
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var draft: SottovaCore.Settings
    @State private var shortest: String
    @State private var longest: String
    @State private var fadeIn: String
    @FocusState private var focus: Field?

    private enum Field { case name, shortest, longest, fadeIn }

    init(edit: PresetEdit) {
        self.edit = edit
        _draft = State(initialValue: edit.preset)
        _shortest = State(initialValue: TypedDuration.format(edit.preset.gapMin))
        _longest = State(initialValue: TypedDuration.format(edit.preset.gapMax))
        _fadeIn = State(initialValue: TypedDuration.format(edit.preset.fadeIn))
    }

    /// The draft with what's typed in it, nil while something can't be read. A bare number is minutes between songs,
    /// seconds in a fade, which is what those fields already say.
    private var saved: SottovaCore.Settings? {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let fade = TypedDuration.parse(fadeIn, unit: 1) else { return nil }
        var preset = draft
        preset.fadeIn = min(fade, 20)
        // overlapping, the gaps' fields are off and keep what they had
        if draft.crossfade { return preset }
        guard let low = TypedDuration.parse(shortest, unit: 60), let high = TypedDuration.parse(longest, unit: 60) else { return nil }
        (preset.gapMin, preset.gapMax) = (min(low, high), max(low, high))
        return preset
    }

    private let overlaps: [Double] = [2, 4, 6, 8, 10]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.replacing.map { "Edit \($0)" } ?? "New preset")
                .role(.sheet)
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            row("Name") {
                TextField("", text: $draft.name)
                    .foregroundStyle(Theme.text)
                    .focused($focus, equals: .name)
                    .modifier(FieldLook(focused: focus == .name))
            }
            row("Between songs") {
                length($shortest, .shortest, unit: 60)
                Text("to").foregroundStyle(Theme.muted)
                length($longest, .longest, unit: 60)
            }
            .disabled(draft.crossfade)
            .opacity(draft.crossfade ? 0.5 : 1)
            row("Fade in") { length($fadeIn, .fadeIn, unit: 1) }
            row("Overlap") { overlap }
            HStack(spacing: 8) {
                if let name = edit.replacing {
                    ThemeButton(title: "Delete") {
                        controller.deletePreset(name)
                        router.presetEdit = nil
                    }
                }
                Spacer(minLength: 0)
                ThemeButton(title: "Cancel") { router.presetEdit = nil }
                    .keyboardShortcut(.cancelAction)
                ThemeButton(title: "Save", primary: true) {
                    guard let saved else { return }
                    controller.savePreset(saved, replacing: edit.replacing)
                    router.presetEdit = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saved == nil)
            }
            .padding(.top, 8)
        }
        .role(.body)
        .padding(20)
        .frame(width: 440)
        .background(Theme.sidebar, in: .rect(cornerRadius: Radius.window))
        .overlay { RoundedRectangle(cornerRadius: Radius.window).strokeBorder(.black.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.55), radius: 25, y: 18)
        .onAppear { focus = .name }
        .onChange(of: focus) { _, field in
            router.typing = field != nil
            tidy()
        }
        .onDisappear {
            router.typing = false
            // the window closed under it
            router.presetEdit = nil
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.muted)
                .frame(width: 96, alignment: .trailing)
            content()
        }
    }

    private func length(_ text: Binding<String>, _ field: Field, unit: Double) -> some View {
        let readable = TypedDuration.parse(text.wrappedValue, unit: unit) != nil
        return TextField("", text: text)
            .foregroundStyle(readable ? Theme.text : Theme.faint)
            .focused($focus, equals: field)
            .modifier(FieldLook(focused: focus == field))
            .frame(width: 64)
            .accessibilityValue(readable ? "" : "can't read this")
    }

    /// Leaving a field shows what it was read as.
    private func tidy() {
        let tidied = { (text: String, unit: Double, field: Field) -> String in
            guard focus != field, let seconds = TypedDuration.parse(text, unit: unit) else { return text }
            return TypedDuration.format(seconds)
        }
        shortest = tidied(shortest, 60, .shortest)
        longest = tidied(longest, 60, .longest)
        if focus != .fadeIn, let fade = TypedDuration.parse(fadeIn, unit: 1) { fadeIn = TypedDuration.format(min(fade, 20)) }
    }

    private var overlap: some View {
        Menu {
            Button("None") { draft.crossfade = false }
            Divider()
            ForEach(overlaps.contains(draft.crossfadeSec) ? overlaps : (overlaps + [draft.crossfadeSec]).sorted(), id: \.self) { seconds in
                Button(TypedDuration.format(seconds)) { (draft.crossfade, draft.crossfadeSec) = (true, seconds) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(draft.crossfade ? TypedDuration.format(draft.crossfadeSec) : "None").foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
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
#endif
