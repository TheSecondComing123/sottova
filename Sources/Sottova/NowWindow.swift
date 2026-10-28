import AppKit
import SwiftUI
import SottovaCore

/// The larger view, for leaving on a second screen.
struct NowWindow: View {
    let controller: Controller

    var body: some View {
        let color = Mocha.accent(for: controller.title)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.headline)
                    .font(.custom("Comic Mono", size: 34).bold())
                    .foregroundStyle(controller.status == .playing ? color : Mocha.text)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(controller.subline(at: context.date))
                        .font(.title3)
                        .foregroundStyle(Mocha.subtext0)
                }
            }

            Timeline(controller: controller, bars: 56)
                .frame(maxHeight: .infinity)
                .padding(20)
                .glassEffect(.regular.tint(color.opacity(0.14)), in: .rect(cornerRadius: 22))

            HStack {
                Controls(controller: controller, size: 42)
                Spacer()
                Text(controller.libraryLine)
                    .font(.callout)
                    .foregroundStyle(Mocha.overlay0)
            }
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 340)
        .tint(color)
        .preferredColorScheme(.dark)
        .containerBackground(.thinMaterial, for: .window)
        .onAppear { Dock.windowOpened(identifier: "now") }
        .onDisappear { Dock.windowClosed() }
    }
}
