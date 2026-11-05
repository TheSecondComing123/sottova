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

    static func waiting(_ hold: Hold) -> NowScreen {
        let line = switch hold {
        case .away: "You're away"
        case .call: "You're on a call"
        case .busy: "Your calendar is busy"
        case .media: "Something else is playing"
        }
        return NowScreen(kind: .silence, title: "Waiting", sub: line)
    }
}

/// The foot of Now: the row coming next, which opens Your day, and a plain line.
public struct NowFoot: Equatable, Sendable {
    public var next: String?
    public var note: String?
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
            return NowScreen(kind: .firstRun, title: "Start with your music")
        }
        if waitingForDevice {
            return NowScreen(kind: .silence, title: "No sound output", sub: "Sottova can't start the audio device. It keeps trying.", action: .openSound)
        }
        guard status != .idle else {
            let quiet = dayPlan(now: now).quiet()
            return NowScreen(kind: .quiet, title: quiet.headline, sub: quiet.line, action: quiet.line.isEmpty ? .openDay : nil)
        }
        if silent || inSilence || status == .resting {
            if let hold, status != .paused { return .waiting(hold) }
            // a row's gap: its name and when it's done, not just the silence
            if let row = soundingRow, let till = dayPlan(now: now).label(of: row.source), till.hasPrefix("till ") {
                let next = machine.restRemaining.map { $0 < 60 ? "next song in under a minute" : "next song in \(Int(($0 / 60).rounded(.up))) min" }
                return NowScreen(kind: .silence, title: row.name, sub: "\(till), \(status == .paused ? "next song waits for Play" : next ?? "")")
            }
            guard status == .paused else { return NowScreen(kind: .silence, title: "Silence") }
            let next = upNext.first.flatMap { catalog.songsByID[$0.path]?.title }
            return NowScreen(kind: .silence, title: "Holding", sub: "\(next ?? "The next song") waits for Play")
        }
        return NowScreen(kind: .piece, title: current?.title ?? title ?? "", sub: nowSub, third: nowThird)
    }

    /// The line at the foot of the page. Reads the whole day, so it's asked for rarely.
    public func nowFoot(now: Date = .now, wakeScheduled: Bool = false) -> NowFoot? {
        if catalog.albums.isEmpty, status == .idle { return nil }
        if status == .idle {
            let quiet = dayPlan(now: now).quiet(wakeScheduled: wakeScheduled)
            return quiet.next == nil && quiet.foot == nil ? nil : NowFoot(next: quiet.next, note: quiet.foot)
        }
        if let row = soundingRow { return dayPlan(now: now).next(sounding: row).map { NowFoot(next: $0) } }
        return sourceName.map { NowFoot(note: "\($0), then everything shuffled.") }
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
        return (status == .paused ? "Paused, " : "") + String(format: "%d:%02d left", left / 60, left % 60)
    }
}
