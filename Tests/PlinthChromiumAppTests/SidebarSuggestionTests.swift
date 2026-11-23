import AppKit
import SwiftUI
import Testing
import PlinthModel
@testable import PlinthChromiumApp

@MainActor
@Suite struct SidebarSuggestionTests {
    @Test func theQuestionNamesTheSites() {
        #expect(SidebarGroupSuggestion.question(["Google", "YouTube"]) == "Group Google & YouTube?")
        #expect(SidebarGroupSuggestion.question(["Docs", "Mail", "Calendar"]) == "Group Docs, Mail & Calendar?")
    }

    /// The card that widened the sidebar: it must fit the column however long the names are.
    @Test func theCardFitsANarrowColumn() {
        let names = ["A very long site name indeed", "Another rather long site name", "And a third one"]
        let suggestion = GroupSuggestion(window: WindowID(), keys: names.map { SiteKey($0) }, siteNames: names)
        let card = SidebarGroupSuggestion(suggestion: suggestion, palette: ShellPalette(.dark, isPrivate: false),
                                          accent: .blue, icon: { _ in nil }, onGroup: {}, onNotNow: {})
        let host = NSHostingController(rootView: card)
        let size = host.sizeThatFits(in: CGSize(width: 220, height: 1000))
        #expect(size.width <= 220)
    }
}
