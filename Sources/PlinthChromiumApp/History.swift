import AppKit
import SwiftUI
import PlinthModel
import PlinthPanels
import PlinthStore

// Plinth's own history panel (⌘Y), as in the Mac app, fed from the shared store's history (which iCloud
// sync shares with other devices). It replaces opening Chromium's chrome://history, which only knew
// what Chromium itself had recorded.

extension BrowserWindowController {
    func toggleHistory() {
        if chrome.panel == .history { dismissPanel() } else { showPanel(.history) }
    }
}

extension ChromiumApp {
    /// Clears history on this Mac and, with iCloud sync on, on the others, as on the Mac. Everything
    /// clears with the sync marker; a range deletes just those entries from the server. Returns how many
    /// entries were removed.
    @discardableResult
    func clearHistory(since date: Date?) -> Int {
        let ids = store.history.filter { date == nil || $0.visitedAt >= date! }.map(\.id)
        let removed = store.clearHistory(since: date)
        if let engine = sync?.engine {
            if date == nil { engine.clearHistory() } else { engine.clearHistory(removing: ids) }
        }
        indexedHistory.subtract(ids)
        return removed
    }
}

extension PanelLayer {
    /// The history panel: searchable, grouped by day. A row opens in a new page.
    func historyPanel(accent: Color) -> some View {
        HistoryView(
            accent: accent,
            icon: { app.pool.favicons.image(for: $0) },
            prepare: {
                // Built off the main thread from a snapshot of the history.
                let entries = app.store.history
                let index = await Task.detached(priority: .userInitiated) { HistoryIndex(entries) }.value
                return { filter in index.page(for: filter) }
            },
            onOpen: { row in
                controller.submit(.result(SearchResult(id: "history-\(row.id.uuidString)", target: .history(row.url),
                                                       title: row.title, subtitle: row.url.absoluteString, key: row.key)))
            },
            onDismiss: { controller.dismissPanel() }
        )
    }
}
