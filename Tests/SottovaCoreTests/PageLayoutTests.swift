import Testing
@testable import SottovaCore

/// Every window the app can be, by the plan's steps: the rules hold over the whole range, not only the sizes looked at.
struct PageLayoutTests {
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

    @Test func theRailFillsThePageWithinItsLimits() {
        for page in Self.windows {
            for span in stride(from: 2.0, through: 24, by: 0.5) {
                for (others, played) in [(0, 0), (3, 0), (2, 19)] {
                    let day = page.day
                    let scale = day.hourHeight(span: span, others: others, played: played)
                    let room = day.railRoom(others: others, played: played)
                    #expect(scale >= DayPlan.Rail.hourHeight && scale <= DayPlan.Rail.maxHourHeight)
                    if scale > DayPlan.Rail.hourHeight { #expect(span * scale <= room + 0.001) }
                    if scale < DayPlan.Rail.maxHourHeight { #expect(span * scale >= min(room, span * DayPlan.Rail.hourHeight) - 0.001) }
                }
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

    @Test func aPaintingFitsItsBlock() {
        for width in [855.0, 1196, 1240, 1470, 1920] {
            let day = PageLayout(windowWidth: width, pageHeight: 898).day
            let width = day.blockWidth(oneColumn: day.narrow)
            #expect(day.painting(block: 52, blockWidth: width) == (40, false))
            for block in stride(from: 52.0, through: 1400, by: 3) {
                let (side, under) = day.painting(block: block, blockWidth: width)
                #expect(side >= 40 && side <= block - 12)
                if under { #expect(side + 12 + 66 <= block && side + 63 <= width) } else { #expect(side + 75 + 220 <= width || side == 40) }
            }
        }
    }

    @Test func whatPlayedShowsWhatFitsAndAtLeastItsShare() {
        #expect(PageLayout(windowWidth: 855, pageHeight: 748).day.playedCap(others: 0) == 3)
        #expect(PageLayout(windowWidth: 1240, pageHeight: 400).day.playedCap(others: 9) == 8)
        #expect(PageLayout(windowWidth: 1470, pageHeight: 898).day.playedCap(others: 0) > 8)
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

    @Test func thresholdsFallWhereThePagesExpect() {
        #expect(PageLayout(windowWidth: 1039, pageHeight: 748).sidebar == 176)
        #expect(PageLayout(windowWidth: 1040, pageHeight: 748).sidebar == 216)
        #expect(PageLayout(windowWidth: 1075, pageHeight: 748).list.narrow)
        #expect(!PageLayout(windowWidth: 1076, pageHeight: 748).list.narrow)
        #expect(PageLayout(windowWidth: 1195, pageHeight: 748).day.narrow)
        #expect(!PageLayout(windowWidth: 1196, pageHeight: 748).day.narrow)
    }
}
