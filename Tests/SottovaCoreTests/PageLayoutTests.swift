import Testing
@testable import SottovaCore

/// Every window the app can be, by the plan's steps: the rules hold over the whole range, not only the sizes looked at.
struct PageLayoutTests {
    @Test func aNarrowNowKeepsThePaintingAtItsCenter() {
        let now = NowLayout(width: 724, height: 848)
        #expect(now.stacked)
        #expect(now.side >= 500)
        #expect(now.left(now.side) >= now.margin)
    }

    @Test func aTallWindowDoesNotStretchTheDay() {
        let short = DayLayout(width: 1024, height: 748).hourHeight(span: 8, others: 0, played: 0)
        let tall = DayLayout(width: 1684, height: 1200).hourHeight(span: 8, others: 0, played: 0)
        #expect((32...36).contains(short))
        #expect(tall == short)
    }

    @Test func nowKeepsAReadingColumnAndQuietTitle() {
        for width in [724.0, 1024, 1254, 1684] {
            let now = NowLayout(width: width, height: 848)
            #expect((280...360).contains(now.textWidth(now.side)))
            #expect(now.titleSize("Waiting", shown: now.side) <= (width < 900 ? 32 : 40))
        }
    }

    private static let windows = stride(from: 855.0, through: 2560, by: 5).flatMap { width in
        stride(from: 640.0, through: 1440, by: 20).map { PageLayout(windowWidth: width, pageHeight: $0) }
    }

    @Test func thePageIsWhatTheSidebarLeaves() {
        for page in Self.windows {
            #expect(page.width + page.sidebar >= 855)
            #expect(page.width >= 679)
            #expect(page.sidebar == (page.narrowWindow ? 176 : 216))
        }
    }

    @Test func coverAndWordsFitBesideOrUnder() {
        for page in Self.windows {
            let now = page.now
            #expect(now.side >= 160)
            #expect(now.left(now.side) >= now.margin)
            if now.stacked {
                #expect(now.side + 48 + 186 <= page.height + 0.5)
                #expect(now.side + 2 * now.margin <= page.width + 0.5)
                #expect(now.coverBottom(now.side) + 186 <= page.height + 0.5 + 24)
            } else {
                #expect(now.side <= page.height - 48 + 0.5)
                #expect(now.coverBottom(now.side) <= page.height)
                // words keep at least the 240 the cover left them, and never leave the page
                #expect(now.textWidth(now.side) >= 239.5)
                #expect(now.textLeft(now.side) + now.textWidth(now.side) <= page.width - now.margin + 0.5)
            }
            #expect(now.bareTextWidth <= page.width - 2 * now.margin)
        }
    }

    @Test func aTallerPageNeverShrinksTheCover() {
        for width in stride(from: 679.0, through: 2344, by: 5) {
            var last = 0.0
            for height in stride(from: 588.0, through: 1440, by: 20) {
                let side = NowLayout(width: width, height: height).side
                #expect(side >= last)
                last = side
            }
        }
    }

    @Test func theRightColumnStaysInRangeAndLeavesTheRailRoom() {
        for page in Self.windows where !page.day.narrow {
            #expect(page.day.right >= 320 && page.day.right <= 420)
            #expect(page.day.blockWidth(oneColumn: false) >= 430)
            #expect(!page.day.oneColumn(others: 1, played: 0))
            #expect(page.day.oneColumn(others: 0, played: 0))
        }
        for page in Self.windows where page.day.narrow {
            #expect(page.day.blockWidth(oneColumn: true) >= 430)
            #expect(page.day.oneColumn(others: 1, played: 1))
        }
    }

    @Test func theTitleTakesItsLineAtEveryWidth() {
        for page in Self.windows where !page.day.narrow {
            #expect(page.day.railRoom(others: 1, played: 0) == page.height - 16 - 24 - 16 - 46)
        }
    }

    @Test func whatPlayedIsCappedByTheColumns() {
        #expect(PageLayout(windowWidth: 855, pageHeight: 748).day.playedCap == 3)
        #expect(PageLayout(windowWidth: 1920, pageHeight: 997).day.playedCap == 8)
    }

    @Test(arguments: [
        (855.0, 748.0, 176.0, true, 679.0, 32.0, 32.0, true),
        (1240, 748, 216, false, 1024, 40, 40, false),
        (1470, 898, 216, false, 1254, 40, 40, false),
        (1920, 997, 216, false, 1704, 40, 40, false),
    ])
    func theSizesTheOwnerLooksAt(window: Double, height: Double, sidebar: Double, narrowWindow: Bool, page: Double, listMargin: Double, nowMargin: Double, dayNarrow: Bool) {
        let layout = PageLayout(windowWidth: window, pageHeight: height)
        #expect(layout.sidebar == sidebar)
        #expect(layout.narrowWindow == narrowWindow)
        #expect(layout.width == page)
        #expect(layout.list.margin == listMargin)
        #expect(layout.now.margin == nowMargin)
        #expect(layout.day.narrow == dayNarrow)
    }

    @Test func aFewPlayedSongsDontHoldAColumnOpen() {
        let day = DayLayout(width: 1100, height: 780)
        #expect(day.oneColumn(others: 0, played: 3))
        #expect(!day.oneColumn(others: 0, played: 4))
        #expect(!day.oneColumn(others: 1, played: 0))
    }

    @Test func detailsKeepUpWithTheTitle() {
        let now = NowLayout(width: 1000, height: 725)
        #expect(now.detailSize(title: 32) == 13)
        #expect(now.detailSize(title: 60) == 18)
        #expect(now.detailSize(title: 84) == 20)
    }

    @Test func aTitleStaysQuietAndALongOneStillFits() {
        let now = NowLayout(width: 1000, height: 725)
        let side = now.side
        #expect(now.titleSize("Waiting", shown: side) <= 40)
        let long = "The road we use to travel when we were kids"
        let size = now.titleSize(long, shown: side)
        #expect(size <= now.titleSize("Waiting", shown: side))
        #expect(size >= 32)
        #expect(size * 0.56 * Double(long.count) / now.textWidth(side) <= 4.01 || size == 32)
        #expect(NowLayout(width: 500, height: 900).titleSize("Waiting", shown: 400) == 32)
    }

    @Test func thresholdsFallWhereThePagesExpect() {
        #expect(PageLayout(windowWidth: 1039, pageHeight: 748).sidebar == 176)
        #expect(PageLayout(windowWidth: 1040, pageHeight: 748).sidebar == 216)
        #expect(PageLayout(windowWidth: 1075, pageHeight: 748).list.narrow)
        #expect(!PageLayout(windowWidth: 1076, pageHeight: 748).list.narrow)
        #expect(PageLayout(windowWidth: 1195, pageHeight: 748).day.narrow)
        #expect(!PageLayout(windowWidth: 1196, pageHeight: 748).day.narrow)
    }

    /// The owner's choice: the painting, title and buttons over the songs at every width, never pinned beside them.
    @Test func theCollectionHeaderSitsOverTheSongsAtEveryWidth() {
        #expect(PageLayout(windowWidth: 900, pageHeight: 748).list.cover == 200)
        #expect(PageLayout(windowWidth: 1075, pageHeight: 748).list.cover == 200)
        #expect(PageLayout(windowWidth: 1440, pageHeight: 852).list.cover == 232)
        #expect(PageLayout(windowWidth: 1900, pageHeight: 997).list.cover == 232)
    }
}
