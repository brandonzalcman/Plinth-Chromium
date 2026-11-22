import CoreGraphics
import Foundation
import Testing
@testable import PlinthChromiumApp

@Suite struct LinkOpeningTests {
    let web = URL(string: "https://example.com/article")!

    @Test func shiftClickArrivesAsANewWindowAndPeeks() {
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: web) == .peek)
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "http://example.com")!) == .peek)
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "file:///tmp/a.html")!) == .peek)
    }

    @Test func aNewWindowWithoutAClickIsAnOrdinaryPage() {
        #expect(LinkOpening.decide(.newWindow, userGesture: false, url: web) == .page(background: false))
    }

    @Test func onlyWebAndFileAddressesPeek() {
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "mailto:a@example.com")!) == .page(background: false))
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "chrome://extensions")!) == .page(background: false))
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: nil) == .page(background: false))
    }

    @Test func commandClickOpensInTheBackgroundAndCommandShiftInFront() {
        #expect(LinkOpening.decide(.backgroundTab, userGesture: true, url: web) == .page(background: true))
        #expect(LinkOpening.decide(.foregroundTab, userGesture: true, url: web) == .page(background: false))
        #expect(LinkOpening.decide(.currentTab, userGesture: true, url: web) == .page(background: false))
    }

    @Test func scriptedPopupsKeepTheirOwnWindow() {
        #expect(LinkOpening.decide(.popup, userGesture: true, url: web) == .popup)
        #expect(LinkOpening.decide(.popup, userGesture: false, url: web) == .popup)
    }

    @Test func theBridgeDispositionsMapAcross() {
        #expect(LinkDisposition(.newWindow) == .newWindow)
        #expect(LinkDisposition(.backgroundTab) == .backgroundTab)
        #expect(LinkDisposition(.foregroundTab) == .foregroundTab)
        #expect(LinkDisposition(.popup) == .popup)
        #expect(LinkDisposition(.currentTab) == .currentTab)
    }
}

@Suite struct PeekLayoutTests {
    @Test func theCardIsCentredOnThePageAtAboutSeventyPercent() {
        let page = CGRect(x: 8, y: 100, width: 1000, height: 700)
        let card = PeekLayout.cardFrame(page: page)
        #expect(abs(card.width - 700) < 0.01)
        #expect(abs(card.height - 490) < 0.01)
        #expect(abs(card.midX - page.midX) <= 0.5)
        #expect(abs(card.midY - page.midY) <= 0.5)
    }

    @Test func aSmallPageKeepsTheCardInsideIt() {
        let page = CGRect(x: 0, y: 0, width: 500, height: 300)
        let card = PeekLayout.cardFrame(page: page)
        #expect(card.width <= page.width - 32)
        #expect(card.height <= page.height - 32)
    }

    @Test func thePreviewSitsBelowTheHeaderInsetOnEverySide() {
        let card = CGRect(x: 100, y: 50, width: 700, height: 490)
        let page = PeekLayout.pageFrame(inCard: card)
        let inset = PeekLayout.pageInset
        #expect(page.minX == card.minX + inset)
        #expect(page.maxX == card.maxX - inset)
        #expect(page.minY == card.minY + inset)
        // The header (and its divider) along the top of the card stays clear.
        #expect(page.maxY == card.maxY - 51 - inset)
    }

    @Test func aTinyCardNeverGivesANegativePage() {
        let page = PeekLayout.pageFrame(inCard: CGRect(x: 0, y: 0, width: 10, height: 20))
        #expect(page.width == 0)
        #expect(page.height == 0)
    }
}
