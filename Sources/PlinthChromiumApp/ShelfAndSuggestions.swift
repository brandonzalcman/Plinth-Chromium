import Foundation
import PlinthRules

/// "Clear all" on the shelf can be undone for a short while; after that the pages are gone for good.
/// And the search engine's suggestions for what's typed in the command bar. Both as on the Mac.
extension ChromiumApp {
    static let shelfUndoWindow: Duration = .seconds(15)

    func clearShelf() {
        guard store.clearShelf() > 0 else { return }
        shelfUndoTask?.cancel()
        shelfUndoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shelfUndoWindow)
            guard !Task.isCancelled, let self else { return }
            self.store.commitClearedShelf()
            self.shelfUndoTask = nil
        }
    }

    func undoClearShelf() {
        shelfUndoTask?.cancel()
        shelfUndoTask = nil
        store.undoClearShelf()
    }

    /// Suggestions from the search engine. Empty when switched off, in a private window, for an
    /// address-like query, for an engine with no endpoint, or on any network error. Sent without cookies.
    func searchSuggestions(for query: String, isPrivate: Bool) async -> [String] {
        guard let url = SearchSuggestions.request(for: query, engine: settings.value.searchEngine,
                                                  enabled: settings.value.searchSuggestionsEnabled,
                                                  isPrivate: isPrivate) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await Self.suggestionSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return SearchSuggestions.parse(data, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let suggestionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}
