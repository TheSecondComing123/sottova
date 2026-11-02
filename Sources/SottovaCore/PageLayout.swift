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
    /// A window of 1400 or more: the cover and words stay put to the left while the songs scroll.
    public let pinned: Bool
    private let width: Double
    public init(width: Double) {
        self.width = width
        narrow = width < 860
        pinned = width >= 1184
    }
    public var margin: Double { narrow ? 32 : 40 }
    public var cover: Double { pinned ? min((width * 0.25).rounded(), 360) : narrow ? 120 : 160 }
}

/// Where things sit on Now: the cover takes what the words and margins leave, up to the page's height, and is centered
/// down it, with the words beside it or under it, whichever lets it be larger. Spare width beside it goes either side.
public struct NowLayout: Equatable, Sendable {
    /// Under the cover: a two-line title and what follows it.
    private static let under = 186.0
    public let width, height, side, margin, gap: Double
    public let stacked: Bool

    public init(width: Double, height: Double) {
        (self.width, self.height) = (width, height)
        let p = min(1, max(0, (width - 679) / (1024 - 679)))
        margin = (32 + 8 * p).rounded()
        gap = (32 + 8 * p).rounded()
        let beside = min(height - 48, width - 2 * margin - gap - (240 + 60 * p).rounded())
        let above = min(height - 48 - Self.under, width - 2 * margin)
        stacked = above > beside
        side = max(stacked ? above : beside, 160).rounded()
    }

    public func left(_ shown: Double) -> Double { stacked ? margin : max(margin, ((width - shown - gap - 456) / 2).rounded()) }
    public func coverBottom(_ shown: Double) -> Double { (height + shown - (stacked ? Self.under : 0)) / 2 }
    public func textLeft(_ shown: Double) -> Double { stacked ? margin : left(shown) + shown + gap }
    public func textWidth(_ shown: Double) -> Double { stacked ? bareTextWidth : min(456, width - textLeft(shown) - margin) }
    public var bareTextWidth: Double { min(560, width - 2 * margin) }

    /// The title beside a large cover grows with it, as far as its longest word and four lines allow.
    public func titleSize(_ title: String, shown: Double) -> Double {
        guard !stacked else { return 32 }
        let room = textWidth(shown)
        let word = title.split(separator: " ").map(\.count).max() ?? 1
        let fit = min(room / (0.6 * Double(word)), room * 4 / (0.56 * Double(max(title.count, 1))))
        return max(32, min(fit, shown * 0.11, 84)).rounded()
    }
}

/// Your day: the rail, with New, Other days and What played beside it or, narrow, around it. The rail takes what they leave.
public struct DayLayout: Equatable, Sendable {
    public static let gap = 32.0
    /// Times and the rail's line, before a block starts.
    public static let blockLeft = 90.0
    private static let top = 16.0, bottom = 24.0
    private static let line = 24.0

    public let width, height: Double
    public let narrow: Bool
    public var margin: Double { narrow ? 32 : 40 }
    public var right: Double { min(max(width * 0.28, 320), 420) }
    public var insets: (top: Double, bottom: Double) { (Self.top, Self.bottom) }

    public init(width: Double, height: Double) {
        (self.width, self.height) = (width, height)
        narrow = width < 980
    }

    /// One column when narrow, or when there's nothing to put beside the rail.
    public func oneColumn(others: Int, played: Int) -> Bool { narrow || others + played == 0 }

    public func blockWidth(oneColumn: Bool) -> Double {
        width - 2 * margin - (oneColumn ? 0 : right + Self.gap) - Self.blockLeft
    }

    private func othersHeight(_ others: Int) -> Double { others == 0 ? 0 : 42 + Double(others) * Self.line }

    /// Height the rail has before it scrolls. 16: the first block sits a little above its time, the last can run past the foot.
    public func railRoom(others: Int, played: Int) -> Double {
        let page = height - Self.top - Self.bottom - 16
        guard oneColumn(others: others, played: played) else { return page }
        let shown = played == 0 ? 0 : 41 + Double(min(played, 3)) * Self.line
        return page - 46 - othersHeight(others) - shown
    }

    /// `span`: the rail's hours once long gaps are drawn short. A long day scrolls.
    public func hourHeight(span: Double, others: Int, played: Int) -> Double {
        min(max(railRoom(others: others, played: played) / span, DayPlan.Rail.hourHeight), DayPlan.Rail.maxHourHeight)
    }

    /// Lines of What played on the page; the rest are behind All.
    public var playedCap: Int { narrow ? 3 : 8 }

    /// A row's painting. In a tall block it fills the width, cropped, over the name and words; a strip too thin to read
    /// as a painting doesn't count as tall. Otherwise it's square beside them. `lines`: the words' lines under it.
    public func painting(block: Double, blockWidth: Double, lines: Int) -> (width: Double, height: Double, under: Bool) {
        let tall = block - 12, wide = blockWidth - 12
        // the name and its gaps, then the words
        let over = tall - 31 - 18 * Double(lines)
        if over >= 160, wide <= over * 4 { return (wide, over, true) }
        // padding, tick and dots across, and room for the words
        let side = max(40, min(tall, blockWidth - 75 - 220))
        return (side, side, false)
    }
}
