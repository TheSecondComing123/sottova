import AVFoundation
import SwiftUI
import SottovaCore

/// "Trim…": drag where a song really starts and ends, to leave out a spoken intro or applause. The file stays as
/// it is; Sottova plays only the part between the handles, fading in and out there as usual.
struct TrimSheet: View {
    let song: Song
    @Environment(Controller.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var length = 0.0
    @State private var peaks: [Float] = []
    @State private var unreadable = false
    @State private var preview: AVAudioPlayer?
    @State private var previewStop: Task<Void, Never>?
    /// Whether hearing a handle paused the music, which comes back when the sheet closes.
    @State private var pausedQueue = false
    /// How long "hear it" plays from a handle.
    private let listen = 6.0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trim \(song.title)")
                    .role(.sheet)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .lineLimit(1)
                Text(song.artist)
                    .font(Role.body.font)
                    .foregroundStyle(Theme.muted)
            }

            Waveform(peaks: peaks, unreadable: unreadable, length: length, start: $start, end: $end, playhead: preview?.isPlaying == true ? preview?.currentTime : nil)
                .frame(height: 112)

            HStack(alignment: .top, spacing: 24) {
                edge("Starts at", value: $start, range: 0...max(end - 1, 0), previewTitle: "Preview start", hear: { hear(from: start) })
                Spacer(minLength: 0)
                edge("Ends at", value: $end, range: min(start + 1, length)...max(length, 1), previewTitle: "Preview end", hear: { hear(from: max(end - listen, start)) })
            }

            HStack(spacing: 8) {
                Text("plays \(Self.clock(end - start)) of \(Self.clock(length)), from the next time it starts")
                    .foregroundStyle(Theme.faint)
                if start > 0 || end < length {
                    ThemeLink(text: "keep all of it", color: Theme.text) {
                        withAnimation(Theme.quick) { (start, end) = (0, length) }
                    }
                    .lineLimit(1)
                }
            }
            .font(Role.column.font)

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ThemeButtonStyle())
                Button("Save") {
                    // a whole file isn't a trim; an end at the file's end is kept open, in case the file is replaced
                    let whole = start < 0.05 && end > length - 0.05
                    controller.setTrim(whole ? nil : Trim(start: start, end: end > length - 0.05 ? nil : end), for: song.id)
                    dismiss()
                }
                .buttonStyle(ThemeButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(length == 0)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.sidebar)
        .presentationBackground(Theme.sidebar)
        .task { await load() }
        .onDisappear {
            preview?.stop()
            previewStop?.cancel()
            if pausedQueue { controller.endPreview() }
        }
    }

    private func edge(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, previewTitle: String, hear: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ValueStepper(value: value, range: range, step: 0.1, format: { Self.clock($0, tenths: true) },
                             help: ("a tenth of a second earlier", "a tenth of a second later"))
                    .accessibilityLabel(label)
                ThemeButton(title: previewTitle, icon: .play, action: hear)
            }
        }
    }

    /// A few seconds from a handle, on a player of its own; the queue is paused so the two don't play at once.
    private func hear(from time: Double) {
        if controller.holdForPreview() {
            pausedQueue = true
        }
        previewStop?.cancel()
        #if !SHOT
        guard let player = preview ?? (try? AVAudioPlayer(contentsOf: URL(filePath: song.id))) else { return }
        player.volume = Float(controller.volume)
        player.currentTime = time
        player.play()
        preview = player
        let stopAt = min(time + listen, end)
        previewStop = Task {
            while !Task.isCancelled, player.isPlaying, player.currentTime < stopAt {
                try? await Task.sleep(for: .milliseconds(50))
                // redraws the playhead
                preview = player
            }
            player.pause()
        }
        #endif
    }

    private func load() async {
        let url = URL(filePath: song.id)
        guard let file = try? AVAudioFile(forReading: url) else {
            unreadable = true
            return
        }
        length = Double(file.length) / file.processingFormat.sampleRate
        let trim = controller.trims[song.id] ?? Trim()
        start = min(trim.start, length)
        end = min(trim.end ?? length, length)
        peaks = await Task.detached(priority: .userInitiated) { Self.peaks(of: url, buckets: 480) }.value
        unreadable = peaks.isEmpty
    }

    /// The loudest sample in each slice of the file, read in chunks so a long piece never sits in memory whole.
    nonisolated static func peaks(of url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { return [] }
        let perBucket = max(Int(file.length) / buckets, 1)
        var peaks = [Float](repeating: 0, count: buckets)
        var frame = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = buffer.floatChannelData![channel]
                for i in 0..<Int(buffer.frameLength) {
                    let bucket = min((frame + i) / perBucket, buckets - 1)
                    peaks[bucket] = max(peaks[bucket], abs(samples[i]))
                }
            }
            frame += Int(buffer.frameLength)
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }

    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let s = max(seconds, 0)
        let whole = Int(s)
        let base = String(format: "%d:%02d", whole / 60, whole % 60)
        return tenths ? base + String(format: ".%d", Int((s - Double(whole)) * 10)) : base
    }
}

/// The file's shape, with the part that's cut dimmed and a handle at each end to drag.
private struct Waveform: View {
    let peaks: [Float]
    let unreadable: Bool
    let length: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (t: Double) in length > 0 ? CGFloat(t / length) * w : 0 }
            ZStack(alignment: .topLeading) {
                // the cut parts sink to the window's ground; the part that plays stays raised
                Theme.background.frame(width: max(x(start), 0), height: h)
                Theme.background.frame(width: max(w - x(end), 0), height: h).offset(x: x(end))
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    for (i, peak) in peaks.enumerated() {
                        let bx = CGFloat(i) * step
                        let t = length * Double(i) / Double(peaks.count)
                        // square root, so quiet speech and soft openings still show beside the loudest bars
                        let bar = max(CGFloat(peak.squareRoot()) * size.height, 1)
                        let rect = CGRect(x: bx, y: (size.height - bar) / 2, width: max(step - 1, 1), height: bar)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(t >= start && t <= end ? Theme.text : Theme.decor))
                    }
                }
                if peaks.isEmpty {
                    Text(unreadable ? "can't read this file" : "reading the file…")
                        .font(Role.column.font)
                        .foregroundStyle(unreadable ? Theme.text : Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let playhead {
                    Rectangle()
                        .fill(Theme.text)
                        .frame(width: 1, height: h)
                        .offset(x: x(playhead))
                }
                handle(at: x(start), height: h) { start = min(max($0 / w * length, 0), max(end - 1, 0)) }
                handle(at: x(end), height: h) { end = max(min($0 / w * length, length), min(start + 1, length)) }
            }
            .coordinateSpace(.named("wave"))
        }
        .padding(.horizontal, 6)
        .background(Theme.raised, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Theme.border))
        .accessibilityHidden(true)
    }

    /// A line through the waveform with a square tab to grab.
    private func handle(at x: CGFloat, height: CGFloat, drag: @escaping (CGFloat) -> Void) -> some View {
        ZStack {
            Rectangle().fill(Theme.text).frame(width: 2, height: height)
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.text)
                .frame(width: 10, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.background, lineWidth: 2))
        }
        .frame(width: 16, height: height)
        .contentShape(.rect)
        .offset(x: x - 8)
        .gesture(DragGesture(coordinateSpace: .named("wave")).onChanged { drag($0.location.x) })
        .pointerStyle(.columnResize)
        .help("drag to move this end")
    }
}
