import Foundation
import Testing
import PlinthModel
@testable import PlinthChromiumApp

@Suite struct SuggestionSnoozeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func suggestion(_ hosts: String...) -> GroupSuggestion {
        GroupSuggestion(window: WindowID(), keys: hosts.map { SiteKey($0) }, siteNames: hosts)
    }

    @Test func oneNotNowQuietsOtherMixesOfTheSameSites() {
        var snooze = SuggestionSnooze()
        snooze.notNow(suggestion("google.com", "youtube.com", "gmail.com"), now: now)
        // The store's next pick from the same sites: no longer shown.
        #expect(snooze.hides(suggestion("google.com", "youtube.com"), now: now + 60))
        #expect(snooze.hides(suggestion("gmail.com", "youtube.com"), now: now + 60))
    }

    @Test func aSuggestionWithANewSiteStillShows() {
        var snooze = SuggestionSnooze()
        snooze.notNow(suggestion("google.com", "youtube.com"), now: now)
        #expect(!snooze.hides(suggestion("google.com", "github.com"), now: now + 60))
    }

    @Test func theSnoozeEndsAfterADayAndStartsAfresh() {
        var snooze = SuggestionSnooze()
        snooze.notNow(suggestion("google.com", "youtube.com"), now: now)
        let later = now + SuggestionSnooze.length + 1
        #expect(!snooze.hides(suggestion("google.com", "youtube.com"), now: later))
        snooze.notNow(suggestion("apple.com", "swift.org"), now: later)
        #expect(snooze.hosts == ["apple.com", "swift.org"])
    }

    @Test func theSnoozeIsSavedWithTheOtherShellPreferences() throws {
        var prefs = ShellPreferences()
        prefs.suggestionSnooze.notNow(suggestion("google.com", "youtube.com"), now: now)
        let back = try JSONDecoder().decode(ShellPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.suggestionSnooze == prefs.suggestionSnooze)
        // An older file without it still loads.
        let old = try JSONDecoder().decode(ShellPreferences.self, from: Data(#"{"tabLayout":"sidebar"}"#.utf8))
        #expect(old.suggestionSnooze == SuggestionSnooze())
    }
}
