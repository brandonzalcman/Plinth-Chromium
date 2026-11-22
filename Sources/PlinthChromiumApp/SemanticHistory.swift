import Foundation
import PlinthAI
import PlinthModel
import PlinthSettings
import PlinthStore

// Semantic history: pages read for a while are embedded on this Mac, and the command bar and the
// shelf list "By meaning" matches after their keyword results. As in the Mac app (AppFeatures.swift).

/// When a page's latest visit goes to the semantic index. Pure, so the rules can be tested.
enum SemanticIndexing {
    /// The visit qualifies (`SemanticIndex.shouldIndex`: 30 s read, http or https), "By meaning" is
    /// on in Settings, the AI is on and working, the page is not in a private window, and this visit
    /// hasn't been sent already this run.
    static func shouldIndex(_ entry: HistoryEntry?, semanticSearchEnabled: Bool, aiAvailable: Bool,
                            isPrivate: Bool, alreadyIndexed: Set<UUID>) -> Bool {
        guard let entry, semanticSearchEnabled, aiAvailable, !isPrivate else { return false }
        return SemanticIndex.shouldIndex(entry) && !alreadyIndexed.contains(entry.id)
    }

    /// Queries shorter than this get no by-meaning results (as on the Mac).
    static let minimumQueryLength = 3
}

extension ChromiumApp {
    /// Sets up on-device AI in this app's storage folder, as `AppController` does.
    func setUpAI() {
        ai = AIService.makeDefault(storageDirectory: storageDirectory)
        applyAISettings(settings.value)
    }

    func applyAISettings(_ value: AppSettings) {
        ai.semanticEnabled = value.semanticSearchEnabled
        ai.summariesEnabled = value.pageSummariesEnabled
    }

    /// A page in a private window (or one Plinth can't place) is never read for the index.
    func isPrivatePage(_ page: PageID) -> Bool {
        guard let window = store.windowID(containing: page) else {
            // Pins live outside windows and are never private; anything else unplaced is treated as private.
            return !store.pins.contains { $0.page.id == page }
        }
        return store.isPrivate(window: window)
    }

    /// Pages read for 30 s or more are embedded once, locally. Called on every dwell tick.
    func indexForMeaningIfNeeded(_ page: PageID) {
        let entry = store.latestHistoryEntry(for: page)
        guard SemanticIndexing.shouldIndex(entry, semanticSearchEnabled: settings.value.semanticSearchEnabled,
                                           aiAvailable: ai.availability.isAvailable, isPrivate: isPrivatePage(page),
                                           alreadyIndexed: indexedHistory), let entry else { return }
        indexedHistory.insert(entry.id)
        Task { @MainActor [weak self] in
            guard let self, let text = await self.pool.readableText(for: page), text.url == entry.url else {
                self?.indexedHistory.remove(entry.id)
                return
            }
            await self.ai.indexIfNeeded(entry: entry, text: text)
        }
    }

    /// "By meaning" results for the command bar and the shelf, after the keyword results.
    func semanticResults(for query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.value.semanticSearchEnabled, trimmed.count >= SemanticIndexing.minimumQueryLength,
              ai.availability.isAvailable else { return [] }
        let matches = await ai.semanticSearch(trimmed, limit: 8)
        return store.semanticResults(matches, excluding: store.search(trimmed, limit: 16), limit: 4)
    }

    /// Writes the semantic index before quitting (waits at most a second).
    func flushAI() {
        guard let ai else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await ai.flush(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    @objc func menuToggleAI(_ sender: Any?) {
        ai.setEnabled(!ai.isEnabled)
        ai.refreshAvailability()
    }
}
