import SwiftUI
import SottovaCore

struct Controls: View {
    let controller: Controller
    var size: CGFloat = 32

    private var running: Bool {
        controller.status == .playing || controller.status == .resting
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: size, height: size)
                }
                .help(running ? "pause" : "play")
                .disabled(controller.tracks.isEmpty)

                Button {
                    controller.skip()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: size, height: size)
                }
                .help("skip to the next track")
                .disabled(controller.status == .idle)
            }
            .font(.system(size: size * 0.42, weight: .semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
    }
}

extension Controller {
    var headline: String {
        switch status {
        case .idle: "sottova"
        case .resting: "resting"
        case .playing, .paused: title ?? "starting"
        }
    }

    func subline(at now: Date) -> String {
        switch status {
        case .idle:
            return tracks.isEmpty ? "add a music folder to start" : "ready when you are"
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        case .resting:
            let left = nextTrackAt?.timeIntervalSince(now) ?? 0
            if left < 60 { return "next track in a moment" }
            if left < 300 { return "next track in a few minutes" }
            return "next track in a while"
        }
    }

    var libraryLine: String {
        guard !folders.isEmpty else { return "no folder yet" }
        var parts = ["\(tracks.count) tracks"]
        if pendingAnalysis > 0 {
            parts.append("measuring loudness, \(pendingAnalysis) left")
        }
        if !skippedFiles.isEmpty {
            parts.append("\(skippedFiles.count) skipped, format not supported")
        }
        return parts.joined(separator: " · ")
    }
}
