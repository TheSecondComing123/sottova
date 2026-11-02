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
    public init(width: Double) { narrow = width < 860 }
    public var margin: Double { narrow ? 32 : 40 }
    public var cover: Double { narrow ? 120 : 160 }
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
}

/// Your day: one column under about 1005 pt, as beside What played a row's words need about 430 pt to stay on their line.
public struct DayLayout: Equatable, Sendable {
    public let height: Double
    public let narrow: Bool
    public var margin: Double { narrow ? 32 : 40 }
    public let right = 320.0

    public init(width: Double, height: Double) {
        self.height = height
        narrow = width < 1005
    }

    /// Wide, the day fills the page's height; narrow, it scrolls with what played below it.
    public func hourHeight(hours: Int) -> Double {
        guard !narrow else { return 32 }
        return min(max((height - 51) / Double(hours), DayPlan.Rail.hourHeight), 120)
    }
}
