import Foundation
import Testing
import PlinthAI
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthStore
@testable import PlinthChromiumApp

@MainActor
@Suite struct AskTests {
    let store = BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: FadeEngine(), storageDirectory: nil)
    let window: WindowID

    init() { window = store.createWindow() }

    @discardableResult func open(_ url: String) -> PageID { store.openPage(url: URL(string: url)!, in: window) }
    var state: WindowState { store.window(window)! }

    @Test func thePageScopeCoversOnlyTheSelectedPage() {
        open("https://example.com/a")
        let b = open("https://example.com/b")
        #expect(BrowserWindowController.askPages(scope: .page, selected: b, window: state) == [b])
    }

    @Test func theSiteScopeCoversEveryPageOfTheSite() {
        let a = open("https://example.com/a")
        let b = open("https://example.com/b")
        open("https://swift.org/")
        #expect(Set(BrowserWindowController.askPages(scope: .site, selected: a, window: state)) == [a, b])
    }

    @Test func theSplitScopeCoversBothSidesAndFallsBackToThePageWithoutOne() {
        let a = open("https://example.com/")
        let b = open("https://swift.org/")
        #expect(BrowserWindowController.askPages(scope: .split, selected: a, window: state) == [a])
        store.split(a, with: b, in: window)
        #expect(Set(BrowserWindowController.askPages(scope: .split, selected: a, window: state)) == [a, b])
    }

    @Test func messagesExplainWhyAskCannotAnswer() {
        #expect(BrowserWindowController.askMessage(for: .available) == nil)
        #expect(BrowserWindowController.askMessage(for: .turnedOff)?.contains("turned off") == true)
        #expect(BrowserWindowController.askMessage(for: .unavailable(reason: "No model")) == "No model")
    }
}
