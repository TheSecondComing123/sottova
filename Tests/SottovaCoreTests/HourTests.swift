import AVFoundation
import Testing
@testable import SottovaCore

/// Alarms that play while you're at the Mac: when their window is open, and what the player does in it.
@MainActor
struct HourTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func hour(from h: Int, _ m: Int, minutes: Int, weekdays: Set<Int> = Set(1...7), source: String = "x") -> Alarm {
        var alarm = Alarm(source: source, name: "Overworld", hour: h, minute: m, weekdays: weekdays, shuffled: true)
        alarm.minutes = minutes
        alarm.whileHere = true
        return alarm
    }

    @Test func aWindowRunsFromItsTimeForItsMinutesOnItsDays() {
        // 2026-10-30 is a Friday
        let desk = hour(from: 15, 0, minutes: 240, weekdays: [6])
        #expect(desk.window(containing: date(2026, 10, 30, 14, 59), calendar: calendar) == nil)
        #expect(desk.window(containing: date(2026, 10, 30, 15, 0), calendar: calendar)?.start == date(2026, 10, 30, 15, 0))
        #expect(desk.window(containing: date(2026, 10, 30, 18, 59), calendar: calendar) != nil)
        #expect(desk.window(containing: date(2026, 10, 30, 19, 0), calendar: calendar) == nil)
        #expect(desk.window(containing: date(2026, 10, 31, 16, 0), calendar: calendar) == nil)
    }

    @Test func aLateWindowRunsPastMidnightOnTheDayItStarted() {
        let late = hour(from: 23, 0, minutes: 120, weekdays: [6])
        #expect(late.window(containing: date(2026, 10, 31, 0, 30), calendar: calendar)?.start == date(2026, 10, 30, 23, 0))
        #expect(late.window(containing: date(2026, 11, 1, 0, 30), calendar: calendar) == nil)
    }

    @Test func aOneOffWindowIsOnlyOnItsDay() {
        var once = hour(from: 9, 30, minutes: 60, weekdays: [])
        once.day = date(2026, 10, 31, 0, 0)
        #expect(once.window(containing: date(2026, 10, 31, 10, 0), calendar: calendar) != nil)
        #expect(once.window(containing: date(2026, 11, 1, 10, 0), calendar: calendar) == nil)
    }

    @Test func birthdaysAndHolidaysDontMakeAnHourWait() {
        #expect(Presence.countsByDefault(birthday: false, title: "alan's calendar"))
        #expect(!Presence.countsByDefault(birthday: true, title: "Birthdays"))
        #expect(!Presence.countsByDefault(birthday: false, title: "Holidays in United States"))
    }

    @Test func aHeldSilenceDoesntCountDownButAPieceGoesOn() {
        var m = Machine(settings: Settings(), seed: 1)
        _ = m.handle(.wait(20))
        #expect(m.status == .resting)
        _ = m.handle(.hold(true))
        _ = m.handle(.tick(60))
        #expect(m.restRemaining == 20)
        _ = m.handle(.hold(false))
        _ = m.handle(.tick(5))
        #expect(m.restRemaining == 15)
        #expect(m.handle(.tick(15)) == [.startNextTrack])
        _ = m.handle(.trackStarted(duration: 100))
        _ = m.handle(.hold(true))
        _ = m.handle(.tick(10))
        guard case .track(let track) = m.phase else { Issue.record("not playing"); return }
        #expect(track.elapsed == 10)
    }

    // MARK: The player in a window

    private func controller(songs: Int = 2) async throws -> (Controller, Album) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: nil)
        for i in 0..<songs {
            let url = try tone(named: "hour-\(i)")
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                        meta: TrackMeta(title: "t\(i)", artist: "a", album: "Overworld", duration: 3))
        }
        c.refreshTracks()
        try await Task.sleep(for: .milliseconds(500))
        let album = try #require(c.catalog.albums.first)
        c.presence = { _ in nil }
        return (c, album)
    }

    /// An hour that opened a minute ago and runs for an hour.
    private func open(_ c: Controller, _ album: Album) -> Alarm {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - 60)
        let alarm = hour(from: parts.hour!, parts.minute!, minutes: 60, source: album.id)
        c.addAlarm(alarm)
        return alarm
    }

    @Test func anHourStartsFromSilenceWhenItsWindowOpens() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        #expect(c.status == .resting)
        #expect((10...45).contains(c.machine.restRemaining ?? 0))
        #expect(c.upNext.count == 2)
        #expect(c.upNext.allSatisfy { $0.source == album.id })
        #expect(c.origin?.shuffled == true)
        // it doesn't wake the Mac, so it isn't the next alarm
        #expect(c.nextAlarm() == nil)
    }

    @Test func anHourTakesOverFromSomethingLeftPaused() async throws {
        let (c, album) = try await controller()
        c.play(album.songs.reversed())
        c.pause()
        _ = open(c, album)
        c.checkHours()
        #expect(c.status == .resting)
        #expect(c.origin?.shuffled == true)
        #expect(c.upNext.count == 2)
    }

    @Test func anHourLeavesWhatYouArePlayingAlone() async throws {
        let (c, album) = try await controller()
        c.play(album.songs.reversed())
        let queued = c.upNext
        _ = open(c, album)
        c.checkHours()
        #expect(c.upNext == queued)
        #expect(c.origin?.shuffled == false)
    }

    @Test func awayTheNextPieceWaitsAndTheMacMaySleep() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.presence = { _ in .away }
        c.checkHours()
        let left = try #require(c.machine.restRemaining)
        c.advance(120)
        #expect(c.status == .resting)
        #expect(c.machine.restRemaining == left)
        #expect(c.hold == .away)
        #expect(c.nextTrackAt == nil)
        c.presence = { _ in nil }
        c.checkHours()
        #expect(c.hold == nil)
        c.advance(left + 0.1)
        #expect(c.status == .playing)
    }

    @Test func theWindowClosingEndsASilenceButNotAPiece() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        c.checkHours(now: .now + 3600)
        #expect(c.status == .idle)
        #expect(c.upNext.isEmpty)

        let (d, other) = try await controller()
        _ = open(d, other)
        d.checkHours()
        d.advance(46)
        #expect(d.status == .playing)
        d.checkHours(now: .now + 3600)
        #expect(d.status == .playing)
        #expect(d.sleepTimer == .afterCurrent)
    }

    @Test func playingSomethingYourselfTakesOverFromTheHour() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.presence = { _ in .call }
        c.checkHours()
        #expect(c.hold == .call)
        c.play(album.songs)
        #expect(c.hold == nil)
        #expect(c.origin?.shuffled == false)
        // and the hour doesn't start again in the same window once that's over
        c.sleep(minutes: 60)
        c.systemWillSleep()
        #expect(c.status == .idle)
        c.checkHours()
        #expect(c.status == .idle)
    }

    @Test func aWindowClosingWhilePausedStillEndsTheHour() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        c.advance(46)
        c.pause()
        c.checkHours(now: .now + 3600)
        #expect(c.sleepTimer == .afterCurrent)
        #expect(c.upNext.isEmpty)
        // the hour's stop isn't yours: what you play next plays on
        c.play(album.songs)
        #expect(c.sleepTimer == nil)
    }

    @Test func theNextHourTakesOverWithoutCuttingAndOnlySooner() async throws {
        let (c, album) = try await controller()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - 60)
        c.addAlarm(hour(from: parts.hour!, parts.minute!, minutes: 2, source: album.id))
        let later = Calendar.current.dateComponents([.hour, .minute], from: .now + 60)
        c.addAlarm(hour(from: later.hour!, later.minute!, minutes: 60, source: album.id))
        c.checkHours()
        let left = try #require(c.machine.restRemaining)
        c.checkHours(now: .now + 120)
        #expect(c.status == .resting)
        #expect(try #require(c.machine.restRemaining) <= left)
        #expect(c.upNext.count == 2)
    }

    @Test func aOneOffHourIsGoneOnceItsWindowCloses() async throws {
        let (c, album) = try await controller()
        var once = hour(from: 9, 0, minutes: 60, weekdays: [], source: album.id)
        once.day = .now - 2 * 86400
        c.addAlarm(once)
        c.checkHours()
        #expect(c.alarms.isEmpty)
    }

    @Test func anHourInOrderPlaysInOrder() async throws {
        let (c, album) = try await controller(songs: 3)
        var alarm = open(c, album)
        alarm.shuffled = false
        c.updateAlarm(alarm)
        c.checkHours()
        #expect(c.upNext.map(\.path) == album.songs.map(\.id))
        #expect(c.origin?.shuffled == false)
    }

    @Test func onlyARowThatMindsTheCalendarWaitsForIt() async throws {
        let (c, album) = try await controller()
        var alarm = open(c, album)
        alarm.heedsCalendar = false
        c.updateAlarm(alarm)
        c.presence = { $0 ? .busy : nil }
        c.checkHours()
        #expect(c.hold == nil)
        alarm.heedsCalendar = true
        c.updateAlarm(alarm)
        c.checkHours()
        #expect(c.hold == .busy)
    }

    @Test func anAlarmThatMindsTheCalendarSkipsABusyDay() async throws {
        let (c, album) = try await controller()
        c.calendarBusy = { true }
        var alarm = Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        c.addAlarm(alarm)
        c.fire(alarm.id, due: .now)
        #expect(c.status != .idle)
        c.sleep(minutes: 1)
        c.systemWillSleep()
        alarm.heedsCalendar = true
        c.updateAlarm(alarm)
        c.fire(alarm.id, due: .now)
        #expect(c.status == .idle)
        #expect(c.problem?.contains("calendar") == true)
    }

    @Test func rowsSavedBeforeTheChoiceKeepWhatTheyDid() throws {
        let old = #"[{"id":"6E1C6A94-13D5-455F-A1BC-8C0E32F97A77","source":"x","name":"a","hour":7,"minute":2,"weekdays":[2],"shuffled":false,"whileHere":true},"#
            + #"{"id":"5DA8B58F-F7AE-4F0C-8FE7-16C12F92132C","source":"y","name":"b","hour":20,"minute":0,"weekdays":[2],"shuffled":false}]"#
        let alarms = try JSONDecoder().decode([Alarm].self, from: Data(old.utf8))
        #expect(alarms.map(\.heedsCalendar) == [true, false])
    }

    @Test func anHourGoesRoundItsCollectionAgain() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        #expect(c.dequeue() != nil)
        #expect(c.dequeue() != nil)
        #expect(c.upNext.isEmpty)
        #expect(c.dequeue() != nil)
        #expect(c.upNext.count == 1)
        #expect(c.origin != nil)
    }

    private func tone(named name: String) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 0.5, count: Int(buffer.frameLength))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-\(name).caf")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}
