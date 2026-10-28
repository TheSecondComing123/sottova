import SwiftUI
import SottovaCore

@main
struct SottovaApp: App {
    private let controller = Controller()

    var body: some Scene {
        MenuBarExtra("Sottova", systemImage: "music.note") {
            Panel(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
