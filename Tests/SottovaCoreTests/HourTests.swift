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

    @Test func heldWithCrossfadeTheNextPieceStillWaits() {
        var settings = Settings()
        settings.crossfade = true
        var m = Machine(settings: settings, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: 10))
        _ = m.handle(.hold(true))
        var effects: [Machine.Effect] = []
        for _ in 0..<1100 { effects += m.handle(.tick(0.01)) }
        #expect(!effects.contains(.startNextTrack))
        #expect(m.status == .resting)
        #expect(m.outgoing == nil)
        _ = m.handle(.gap(0))
        #expect(m.handle(.tick(0.01)).isEmpty)
        _ = m.handle(.hold(false))
        #expect(m.handle(.tick(0.01)) == [.startNextTrack])
    }

    // MARK: The player in a window

    private func controller(songs: Int = 2, storage: URL? = nil, playlists: URL? = nil) async throws -> (Controller, Album) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: storage, playlistFolder: playlists)
        for i in 0..<songs {
            let url = try tone(named: "hour-\(i)")
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                        meta: TrackMeta(title: "t\(i)", artist: "a", album: "Overworld", duration: 3))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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

    @Test func overlappingRowsTheLatestStartWins() async throws {
        let (c, album) = try await controller()
        let earlier = Calendar.current.dateComponents([.hour, .minute], from: .now - 120)
        var first = hour(from: earlier.hour!, earlier.minute!, minutes: 60, source: album.id)
        first.shuffled = false
        c.addAlarm(first)
        _ = open(c, album)
        #expect(c.openHour()?.id != first.id)
        c.checkHours()
        #expect(c.origin?.shuffled == true)
    }

    /// The same clock time tomorrow, whatever the clocks do tonight.
    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    }

    @Test func aPiecePausedYesterdayDoesntCarryOnIntoTodaysWindow() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        c.advance(46)
        c.pause()
        // a lid closed mid-hour and opened at the same time tomorrow, with no check in between
        c.checkHours(now: tomorrow)
        #expect(c.status == .resting)
        #expect(c.upNext.count == 2)
        #expect(c.sleepTimer == nil)
    }

    @Test func aPieceStillPlayingGoesOnIntoTheNextWindowAsThatWindowsHour() async throws {
        let (c, album) = try await controller()
        _ = open(c, album)
        c.checkHours()
        c.advance(46)
        #expect(c.status == .playing)
        let playing = c.current
        #expect(c.upNext.count == 1)
        c.checkHours(now: tomorrow)
        #expect(c.status == .playing)
        #expect(c.current == playing)
        #expect(c.sleepTimer == nil)
        #expect(c.upNext.count == 2)
    }

    // MARK: Parts

    private func rotating(_ c: Controller, _ album: Album) -> Alarm {
        var row = open(c, album)
        row.rotates = true
        row.parts = 2
        c.updateAlarm(row)
        return row
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-hour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aPartHeldAllWindowIsntUsedUp() async throws {
        let (c, album) = try await controller(songs: 4)
        _ = rotating(c, album)
        c.presence = { _ in .away }
        c.checkHours()
        c.advance(100)
        c.checkHours(now: .now + 3600)
        #expect(c.status == .idle)
        #expect(c.alarms.first?.nextPart == 0)
    }

    @Test func aPartIsUsedUpWhenItSoundsAndOnlyOnce() async throws {
        let (c, album) = try await controller(songs: 4)
        let row = rotating(c, album)
        let part = c.parts(for: row)[0].map(\.id)
        c.checkHours()
        #expect(c.alarms.first?.nextPart == 0)
        #expect(Set(c.upNext.map(\.path)) == Set(part))
        c.advance(46)
        #expect(c.status == .playing)
        #expect(c.alarms.first?.nextPart == 1)
        // the next piece, then round again: still the part it's on
        c.advance(3.1)
        c.advance(121)
        #expect(c.status == .playing)
        #expect(c.alarms.first?.nextPart == 1)
        #expect(c.upNext.isEmpty)
        #expect(part.contains(try #require(c.dequeue())))
    }

    @Test func playingSomethingElseFirstLeavesThePartForNextTime() async throws {
        let (c, album) = try await controller(songs: 4)
        _ = rotating(c, album)
        c.checkHours()
        c.play(album.songs)
        #expect(c.status == .playing)
        c.advance(1.1)
        #expect(c.alarms.first?.nextPart == 0)
    }

    @Test func overlappingRowsDontUseAPartUpTwice() async throws {
        let (c, album) = try await controller(songs: 4)
        let row = rotating(c, album)
        let part = c.parts(for: row)[0].map(\.id)
        c.checkHours()
        c.advance(46)
        #expect(c.alarms.first?.nextPart == 1)
        // one starts inside it, ends, and the first has the time again
        let inside = Calendar.current.dateComponents([.hour, .minute], from: .now + 120)
        var other = hour(from: inside.hour!, inside.minute!, minutes: 5, source: album.id)
        other.shuffled = false
        c.addAlarm(other)
        c.checkHours(now: .now + 180)
        #expect(c.origin?.shuffled == false)
        c.checkHours(now: .now + 600)
        #expect(c.origin?.shuffled == true)
        #expect(Set(c.upNext.map(\.path)) == Set(part))
        c.advance(3.1)
        c.advance(121)
        #expect(c.status == .playing)
        #expect(c.alarms.first?.nextPart == 1)
    }

    @Test func aStoppedHourStaysStoppedAfterARelaunch() async throws {
        let storage = try temp()
        let (c, album) = try await controller(storage: storage)
        _ = open(c, album)
        c.checkHours()
        c.sleep(minutes: 60)
        c.systemWillSleep()
        #expect(c.status == .idle)
        let (again, _) = try await controller(storage: storage)
        again.loadAlarms()
        again.checkHours()
        #expect(again.status == .idle)
    }

    @Test func aPartWithNoSongsLeftDoesntMoveTheOthers() async throws {
        let (c, album) = try await controller(songs: 2, playlists: try temp())
        let songs = album.songs
        let id = try #require(c.newPlaylist(songs: songs))
        c.add([Song(id: "/gone", title: "t", work: "t", detail: nil, artist: "p", album: "a", albumID: "a", albumArtist: "",
                    composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: "/gone")], to: id, at: 1)
        c.setBreak(true, at: 1, in: id)
        c.setBreak(true, at: 2, in: id)
        var row = open(c, album)
        row.source = id
        row.rotates = true
        row.nextPart = 2
        c.updateAlarm(row)
        #expect(c.parts(for: row).map(\.count) == [1, 0, 1])
        #expect(c.nextPartName(for: row) == "part 3")
        c.checkHours()
        #expect(c.upNext.map(\.path) == [songs[1].id])
        c.advance(46)
        #expect(c.alarms.first?.nextPart == 0)
        // on the part that's gone, the one after it plays
        var next = try #require(c.alarms.first)
        next.nextPart = 1
        #expect(c.nextPartName(for: next) == "part 3")
    }

    private struct DeviceGone: Error {}

    @Test func anAlarmThatCantStartYetKeepsItsPart() async throws {
        let (c, album) = try await controller(songs: 4)
        var row = Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        row.rotates = true
        row.parts = 2
        c.addAlarm(row)
        var fails = 1
        c.startEngine = { engine in
            if fails > 0 {
                fails -= 1
                throw DeviceGone()
            }
            try engine.start()
        }
        c.fire(row.id, due: .now)
        #expect(c.alarms.first?.nextPart == 0)
        for _ in 0..<400 where c.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.current != nil)
        #expect(c.alarms.first?.nextPart == 1)
    }

    @Test func anAlarmWhoseFilesAreAllBadDoesntWanderOrBlockPlay() async throws {
        let (c, _) = try await controller()
        let other = try tone(named: "hour-other")
        c.library.entries[other.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                      meta: TrackMeta(title: "other", artist: "b", album: "Elsewhere", duration: 3))
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let bad = try temp().appending(path: "bad.caf")
        try Data("not audio".utf8).write(to: bad)
        c.library.entries[bad.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                    meta: TrackMeta(title: "bad", artist: "c", album: "Bad", duration: 3))
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let row = Alarm(source: try #require(c.catalog.albums.first { $0.title == "Bad" }).id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.status == .idle)
        #expect(c.current == nil)
        c.toggle()
        #expect(c.status == .playing)
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
