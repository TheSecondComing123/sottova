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
        recent.append(pick)
        if recent.count > 2 * n {
            recent.removeFirst(recent.count - n)
        }
        return pick
    }
}
