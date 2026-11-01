import SwiftUI
import SottovaCore

/// The sleep timer's choices, here and in the Controls menu.
struct SleepChoices: View {
    let controller: Controller

    var body: some View {
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        if let timer {
            Button("stops \(Format.sleep(timer, resting: resting, at: .now, sentence: true))") {}
                .disabled(true)
            Divider()
        }
        Toggle(resting ? "After the next song" : "After this song", isOn: Binding(
            get: { timer == .afterCurrent },
            set: { $0 ? controller.sleepAfterCurrent() : controller.cancelSleep() }))
        Divider()
        ForEach([15.0, 30, 45, 60, 90], id: \.self) { minutes in
            Button(Format.minutes(minutes * 60)) { controller.sleep(minutes: minutes) }
        }
        if timer != nil {
            Divider()
            Button("Turn off") { controller.cancelSleep() }
        }
    }
}

/// The moon: off it's a quiet icon; set, it takes a color and says how long is left. The minutes count down, so
/// only "after this piece" gets a check in the menu.
struct SleepButton: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        Menu {
            SleepChoices(controller: controller)
        } label: {
            // the label only needs whole minutes, so twice a minute is enough
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 4) {
                    Ph.moon.icon(size: 16)
                        .foregroundStyle(timer == nil ? Theme.muted : Theme.accent(10))
                    if let timer {
                        Text(Format.sleep(timer, resting: resting, at: context.date))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 32, minHeight: 32)
                .hoverable(radius: 8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(controller.status == .idle)
        .animation(Theme.quick, value: timer)
        .help("sleep timer")
        .accessibilityLabel("sleep timer")
        .accessibilityValue(timer.map { Format.sleep($0, resting: resting, at: .now) } ?? "off")
    }
}
