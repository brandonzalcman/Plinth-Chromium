import Foundation
import Testing
import PlinthModel
import PlinthReader
@testable import PlinthChromiumApp

@Suite struct SemanticIndexingTests {
    func entry(_ url: String = "https://example.com/article", dwell: TimeInterval = 40) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: "An article", name: "Article", key: SiteKey("example.com"),
                     visitedAt: Date(), dwell: dwell)
    }

    func decide(_ e: HistoryEntry?, enabled: Bool = true, available: Bool = true, isPrivate: Bool = false,
                indexed: Set<UUID> = []) -> Bool {
        SemanticIndexing.shouldIndex(e, semanticSearchEnabled: enabled, aiAvailable: available,
                                     isPrivate: isPrivate, alreadyIndexed: indexed)
    }

    @Test func aPageReadForHalfAMinuteIsIndexed() {
        #expect(decide(entry()))
    }

    @Test func aShortVisitIsNot() {
        #expect(!decide(entry(dwell: 10)))
        #expect(decide(entry(dwell: 30)))
    }

    @Test func onlyWebPagesAreIndexed() {
        #expect(!decide(entry("file:///Users/me/notes.html")))
        #expect(!decide(entry("chrome://extensions")))
        #expect(decide(entry("http://example.com")))
    }

    @Test func privatePagesAreNeverIndexed() {
        #expect(!decide(entry(), isPrivate: true))
    }

    @Test func settingsAndAvailabilityAreHonoured() {
        #expect(!decide(entry(), enabled: false))
        #expect(!decide(entry(), available: false))
        #expect(!decide(nil))
    }

    @Test func aVisitIsSentOnlyOnce() {
        let e = entry()
        #expect(!decide(e, indexed: [e.id]))
        #expect(decide(e, indexed: [UUID()]))
    }
}

@Suite struct PageTextScriptTests {
    @Test func theReaderScriptIsCalledWithItsArguments() {
        let script = PageTextScript.expression(limit: 500)
        #expect(script.hasPrefix("(function (limit, focusLength) {"))
        #expect(script.hasSuffix("})(500, \(ReaderScript.focusExcerptLength))"))
        #expect(script.contains(ReaderScript.source))
        #expect(PageTextScript.expression(limit: -3).hasSuffix("})(0, \(ReaderScript.focusExcerptLength))"))
    }

    @Test func plainTextIsTidiedAndCapped() {
        let url = URL(string: "https://example.com")!
        let text = PageTextScript.plainText("  Hello   there \n\n\n  second\tline  \n", pageURL: url, title: "T", limit: 100)
        #expect(text?.text == "Hello there\nsecond line")
        #expect(text?.title == "T")
        #expect(text?.focusExcerpt == nil)
        #expect(PageTextScript.plainText("abcdef", pageURL: url, title: "", limit: 3)?.text == "abc")
        #expect(PageTextScript.plainText(" \n \n", pageURL: url, title: "", limit: 100) == nil)
        #expect(PageTextScript.plainText(nil, pageURL: url, title: "", limit: 100) == nil)
    }
}
