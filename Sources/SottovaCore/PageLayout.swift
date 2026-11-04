/// Where a window's space goes, from its size alone. Nothing here reads its own output: the window decides the sidebar,
/// the sidebar the page, and the page everything inside it.
public struct PageLayout: Equatable, Sendable {
    public let width, height, sidebar: Double
    /// The window, not the page: the sidebar and the bar's spare room go by this.
    public let narrowWindow: Bool

    /// `pageHeight`: the window's content less the bar.
    public init(windowWidth: Double, pageHeight: Double) {
        narrowWindow = windowWidth < 1040
        sidebar = narrowWindow ? 176 : 216
        width = windowWidth - sidebar
        height = pageHeight
    }

    /// Songs, collections and free music.
    public var list: ListLayout { ListLayout(width: width) }
    public var now: NowLayout { NowLayout(width: width, height: height) }
    public var day: DayLayout { DayLayout(width: width, height: height) }
}

public struct ListLayout: Equatable, Sendable {
    public let narrow: Bool
    public init(width: Double) {
        narrow = width < 860
    }
    public var margin: Double { narrow ? 32 : 40 }
    /// A collection's painting, with its title and buttons beside it over the songs.
    public var cover: Double { narrow ? 200 : 232 }
}

/// Where things sit on Now: the cover takes what the words and margins leave, up to the page's height, and is centered
/// down it, with the words beside it or under it, whichever lets it be larger. Spare width beside it goes either side.
public struct NowLayout: Equatable, Sendable {
    /// Under the cover: a two-line title and what follows it.
    private static let under = 248.0
    public let width, height, side, margin, gap: Double
    public let stacked: Bool

    public init(width: Double, height: Double) {
        (self.width, self.height) = (width, height)
        let p = min(1, max(0, (width - 679) / (1024 - 679)))
        margin = (32 + 8 * p).rounded()
        gap = (32 + 8 * p).rounded()
        let words = min(360, max(280, width * 0.28))
        let beside = min(height - 48, width - 2 * margin - gap - words)
        let above = min(height - 48 - Self.under, width - 2 * margin)
        stacked = above > beside
        side = max(stacked ? above : beside, 160).rounded()
    }

    public func left(_ shown: Double) -> Double { stacked ? max(margin, ((width - shown) / 2).rounded()) : max(margin, ((width - shown - gap - min(360, max(280, width * 0.28))) / 2).rounded()) }
    public func coverBottom(_ shown: Double) -> Double { (height + shown - (stacked ? Self.under : 0)) / 2 }
    public func textLeft(_ shown: Double) -> Double { stacked ? left(shown) : left(shown) + shown + gap }
    public func textWidth(_ shown: Double) -> Double { stacked ? bareTextWidth : min(360, max(280, width * 0.28), width - textLeft(shown) - margin) }
    public var bareTextWidth: Double { min(360, width - 2 * margin) }

    /// The lines under a title keep up with it, so a large title doesn't sit on specks.
    public func detailSize(title: Double) -> Double { max(13, min(20, (title * 0.3).rounded())) }

    /// The painting leads; the title keeps the scale of a reading column.
    public func titleSize(_ title: String, shown: Double) -> Double {
        guard !stacked else { return 32 }
        let room = textWidth(shown)
        let word = title.split(separator: " ").map(\.count).max() ?? 1
        let fit = min(room / (0.6 * Double(word)), room * 4 / (0.56 * Double(max(title.count, 1))))
        return max(32, min(fit, width < 900 ? 32 : 40)).rounded()
    }
}

/// Your day keeps a compact workspace, with Other days and What played beside it when there is room.
public struct DayLayout: Equatable, Sendable {
    public static let gap = 32.0
    /// Times and the rail's line, before a block starts.
    public static let blockLeft = 90.0
    private static let top = 16.0, bottom = 24.0
    private static let line = 24.0

    public let width, height: Double
    public let narrow: Bool
    public var margin: Double { narrow ? 32 : 40 }
    public var contentWidth: Double { min(width - 2 * margin, 1100) }
    public var right: Double { min(max(contentWidth * 0.28, 320), 420) }
    public var insets: (top: Double, bottom: Double) { (Self.top, Self.bottom) }

    public init(width: Double, height: Double) {
        (self.width, self.height) = (width, height)
        narrow = width < 980
    }

    /// One column when narrow, or when there's too little to fill a column beside the rail.
    public func oneColumn(others: Int, played: Int) -> Bool { narrow || (others == 0 && played < 4) }

    public func blockWidth(oneColumn: Bool) -> Double {
        contentWidth - (oneColumn ? 0 : right + Self.gap) - Self.blockLeft
    }

    private func othersHeight(_ others: Int) -> Double { others == 0 ? 0 : 42 + Double(others) * Self.line }

    /// Height the rail has before it scrolls, under the title. 16: the first block sits a little above its time, the last can run past the foot.
    public func railRoom(others: Int, played: Int) -> Double {
        let page = height - Self.top - Self.bottom - 16 - 46
        guard oneColumn(others: others, played: played) else { return page }
        let shown = played == 0 ? 0 : 41 + Double(min(played, 3)) * Self.line
        return page - othersHeight(others) - shown
    }

    /// Extra window height leaves air around the day instead of stretching its events.
    public func hourHeight(span: Double, others: Int, played: Int) -> Double {
        34
    }

    /// Lines of What played on the page; the rest are behind All.
    public var playedCap: Int { narrow ? 3 : 8 }
}
