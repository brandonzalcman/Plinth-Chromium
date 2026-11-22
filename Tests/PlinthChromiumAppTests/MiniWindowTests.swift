import Foundation
import Testing
import PlinthModel
@testable import PlinthChromiumApp

@Suite struct AdoptionSlotTests {
    let url = URL(string: "https://example.com/a")!

    @Test func theNextPageWithTheAddressTakesTheItemOnce() {
        var slot = AdoptionSlot<String>()
        slot.offer("browser", url: url)
        #expect(slot.take(matching: URL(string: "https://example.com/b")!) == nil)
        #expect(slot.take(matching: url) == "browser")
        #expect(slot.take(matching: url) == nil)
        #expect(slot.clear() == nil)
    }

    @Test func anUntakenOfferIsHandedBackWhenCleared() {
        var slot = AdoptionSlot<String>()
        slot.offer("browser", url: url)
        #expect(slot.clear() == "browser")
        #expect(slot.pending == nil)
    }

    @Test func aNewOfferDisplacesTheOldOne() {
        var slot = AdoptionSlot<String>()
        #expect(slot.offer("first", url: url) == nil)
        #expect(slot.offer("second", url: url) == "first")
        #expect(slot.take(matching: url) == "second")
    }
}

@Suite struct MiniPromotionTests {
    let a = WindowID(), b = WindowID(), p = WindowID()

    func c(_ id: WindowID, isPrivate: Bool = false, showing: Bool = true) -> MiniPromotion.Candidate {
        .init(id: id, isPrivate: isPrivate, isShowing: showing)
    }

    @Test func goesIntoTheKeyMainWindow() {
        #expect(MiniPromotion.target(keyWindow: b, windows: [c(a), c(b)]) == b)
    }

    @Test func neverIntoAPrivateWindow() {
        #expect(MiniPromotion.target(keyWindow: p, windows: [c(p, isPrivate: true), c(a)]) == a)
        #expect(MiniPromotion.target(keyWindow: p, windows: [c(p, isPrivate: true)]) == nil)
    }

    @Test func prefersAWindowOnScreen() {
        #expect(MiniPromotion.target(keyWindow: nil, windows: [c(a, showing: false), c(b)]) == b)
        // A hidden one is used (and shown) when it is all there is.
        #expect(MiniPromotion.target(keyWindow: nil, windows: [c(a, showing: false)]) == a)
        #expect(MiniPromotion.target(keyWindow: a, windows: [c(a, showing: false), c(b)]) == b)
    }

    @Test func noWindowMeansANewOne() {
        #expect(MiniPromotion.target(keyWindow: nil, windows: []) == nil)
    }

    @Test func thePageKeepsWhereItGot() {
        let start = URL(string: "https://example.com/start")!
        #expect(MiniPromotion.address(current: "https://example.com/later#x", initial: start).absoluteString == "https://example.com/later#x")
        #expect(MiniPromotion.address(current: "", initial: start) == start)
        #expect(MiniPromotion.address(current: "not a url", initial: start) == start)
    }

    @Test func thePageSitsBelowTheStrip() {
        let size = CGSize(width: 980, height: 720)
        let page = MiniWindowLayout.pageFrame(in: size, fullScreen: false)
        #expect(page.maxY == size.height - MiniWindowLayout.stripHeight)
        #expect(page.minX == ContentGeometry.margin && page.minY == ContentGeometry.margin)
        #expect(MiniWindowLayout.pageFrame(in: size, fullScreen: true) == CGRect(origin: .zero, size: size))
    }
}
