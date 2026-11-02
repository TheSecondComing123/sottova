import SwiftUI
import SottovaCore

/// The sleep timer's choices in the Controls menu.
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
