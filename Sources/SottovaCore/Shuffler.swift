/// A shuffle bag that also avoids the last N tracks played, across refills.
struct Shuffler {
    var recent: [String] = []
    private var bag: [String] = []

    mutating func next(from tracks: [String], avoidingLast n: Int = 10, using rng: inout some RandomNumberGenerator) -> String? {
        guard !tracks.isEmpty else { return nil }
        // with a small library, avoiding N would block everything
        let blocked = Set(recent.suffix(min(n, tracks.count - 1)))
        let available = Set(tracks)
        bag.removeAll { !available.contains($0) }
        if !bag.contains(where: { !blocked.contains($0) }) {
            bag.insert(contentsOf: tracks.shuffled(using: &rng), at: 0)
        }
        let index = bag.lastIndex { !blocked.contains($0) }!
        let pick = bag.remove(at: index)
        note(pick)
        return pick
    }

    /// Records a track the listener picked, so shuffle doesn't bring it back right after.
    mutating func note(_ path: String) {
        recent.append(path)
        if recent.count > 200 {
            recent.removeFirst(recent.count - 100)
        }
    }
}
