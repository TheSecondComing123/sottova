import Testing
@testable import SottovaCore

struct ShufflerTests {
    @Test(arguments: [1, 2, 5, 50])
    func neverRepeatsWithinTheLastN(librarySize: Int) {
        let tracks = (0..<librarySize).map { "track \($0)" }
        let n = min(10, librarySize - 1)
        var shuffler = Shuffler()
        var rng = SplitMix64(seed: UInt64(librarySize))
        var picks: [String] = []
        for _ in 0..<10_000 {
            let pick = shuffler.next(from: tracks, using: &rng)!
            #expect(!picks.suffix(n).contains(pick))
            picks.append(pick)
        }
        // the bag keeps plays even: every track within one play of the others
        let counts = Dictionary(grouping: picks, by: { $0 }).mapValues(\.count)
        #expect(counts.count == librarySize)
        #expect(counts.values.max()! - counts.values.min()! <= 1)
    }

    @Test func recentPlaysCarryAcrossARelaunch() {
        let tracks = (0..<20).map { "track \($0)" }
        var shuffler = Shuffler()
        shuffler.recent = Array(tracks.prefix(10))
        var rng = SplitMix64(seed: 7)
        let pick = shuffler.next(from: tracks, using: &rng)!
        #expect(!tracks.prefix(10).contains(pick))
    }

    @Test func removedTracksStopPlaying() {
        var shuffler = Shuffler()
        var rng = SplitMix64(seed: 3)
        _ = shuffler.next(from: ["a", "b", "c"], using: &rng)
        for _ in 0..<20 {
            #expect(shuffler.next(from: ["a"], using: &rng) == "a")
        }
    }
}
