import SwiftUI
import SottovaCore

/// The sleep timer's choices in the Controls menu.
struct SleepChoices: View {
    let controller: Controller

    var body: some View {
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        // what the times are for, said before them
        Button(timer.map { "Stops \(Format.sleep($0, resting: resting, at: .now, sentence: true))" } ?? "Stop the music") {}
            .disabled(true)
        Divider()
        Toggle(resting ? "After the next song" : "After this song", isOn: Binding(
            get: { timer == .afterCurrent },
            set: { $0 ? controller.sleepAfterCurrent() : controller.cancelSleep() }))
        Divider()
        ForEach([15.0, 30, 45, 60, 90], id: \.self) { minutes in
            Button("In \(Format.minutes(minutes * 60))") { controller.sleep(minutes: minutes) }
        }
        if timer != nil {
            Divider()
            Button("Turn off") { controller.cancelSleep() }
        }
    }
}
