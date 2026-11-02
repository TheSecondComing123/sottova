import Foundation

/// The words on Now.
public struct NowScreen: Equatable, Sendable {
    public enum Kind: Sendable { case firstRun, reading, quiet, piece, silence }
    public enum Action: Sendable { case openDay, openSound }

    public var kind: Kind
    public var title: String
    public var sub = ""
    public var third: String?
    public var action: Action?

    public init(kind: Kind, title: String, sub: String = "", third: String? = nil, action: Action? = nil) {
        (self.kind, self.title, self.sub, self.third, self.action) = (kind, title, sub, third, action)
    }

    public var actionTitle: String? {
        switch action {
        case .openDay: "Open Your day"
        case .openSound: "Open Sound settings"
        case nil: nil
        }
    }

    static func waiting(_ hold: Hold, row: String?) -> NowScreen {
        let name = row ?? "It"
        let line = switch hold {
        case .away: "You're away. \(name) picks up when you're back."
        case .call: "You're on a call. \(name) picks up after."
        case .busy: "Your calendar is busy."
        case .media: "Something else is playing. \(name) waits for it."
        }
        return NowScreen(kind: .silence, title: "Waiting", sub: line)
    }

    static let pitch = "Pieces arrive out of silence, at the hours you choose."
}

extension Controller {
    /// `silent`: the screen's own fall has ended, which comes before the audio's. Polled, like the state it reads.
    public func nowScreen(now: Date = .now, silent: Bool = false) -> NowScreen {
        // music picked up from the last run plays before the catalog is built: that isn't a first run
        if catalog.albums.isEmpty, status == .idle {
            if pendingAnalysis > 0, let folder = folders.first {
                let done = max(0, tracks.count - pendingAnalysis)
                return NowScreen(kind: .reading, title: "Reading \(folder.lastPathComponent)", sub: "\(done) of \(tracks.count)")
            }
            return NowScreen(kind: .firstRun, title: "Drop your music here")
        }
        if waitingForDevice {
            return NowScreen(kind: .silence, title: "No sound output", sub: "Sottova can't start the audio device. It keeps trying.", action: .openSound)
        }
        guard status != .idle else {
            let quiet = dayPlan(now: now).quiet()
            return NowScreen(kind: .quiet, title: quiet.headline, sub: quiet.line, action: alarms.contains(where: \.on) ? nil : .openDay)
        }
        if silent || inSilence || status == .resting {
            if let hold, status != .paused { return .waiting(hold, row: soundingRow?.name) }
            return NowScreen(kind: .silence, title: "Silence", sub: status == .paused ? "Paused" : "")
        }
        return NowScreen(kind: .piece, title: current?.title ?? title ?? "", sub: nowSub, third: nowThird)
    }

    /// The line at the foot of the page. Reads the whole day, so it's asked for rarely.
    public func nowFoot(now: Date = .now, wakeScheduled: Bool = false) -> String? {
        if catalog.albums.isEmpty, status == .idle { return NowScreen.pitch }
        if status == .idle { return dayPlan(now: now).quiet(wakeScheduled: wakeScheduled).foot }
        if let row = soundingRow { return dayPlan(now: now).foot(sounding: row) }
        return sourceName.map { "\($0), then everything shuffled." }
    }

    public var sourceName: String? {
        guard let id = playingFrom else { return nil }
        return playlists.first { $0.id == id }?.name ?? catalog.albums.first { $0.id == id }?.title
    }

    private var nowSub: String {
        guard let song = current else { return sourceName ?? "" }
        var who = [song.artist]
        if let composer = song.composer, composer != song.artist { who.insert(composer, at: 0) }
        return who.joined(separator: ", ")
    }

    private var nowThird: String? {
        if status != .paused, rising {
            return soundingRow?.volume.map { "Rising to \(Int(($0 * 100).rounded()))%" } ?? "Rising"
        }
        if status != .paused, easing {
            guard case .at(let date)? = sleepTimer else { return "Easing down" }
            let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "Easing down, stops at %d:%02d", ((clock.hour ?? 0) + 11) % 12 + 1, clock.minute ?? 0)
        }
        guard let track else { return nil }
        let left = max(0, Int((track.duration - track.elapsed).rounded(.up)))
        return String(format: "%d:%02d left", left / 60, left % 60)
    }
}
