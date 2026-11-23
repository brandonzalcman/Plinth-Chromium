import AppKit
import PlinthAI
import PlinthLoyalty
import PlinthModel
import PlinthPanels

/// Ask About This Page (⌘J): a question about the page, its site's pages or a split, answered on
/// device from the pages' readable text. Same scopes and wording as the Mac app.
extension BrowserWindowController {
    func openAsk() {
        guard let selected = app.store.window(windowID)?.selectedPageID else { return }
        app.ai.refreshAvailability()
        let scopes = askScopes()
        if !scopes.contains(where: { $0.scope == chrome.askScope }) { chrome.askScope = scopes.first?.scope ?? .page }
        if let split = app.store.window(windowID)?.split, split.contains(selected) { chrome.askScope = .split }
        chrome.askMessage = Self.askMessage(for: app.ai.availability)
        showPanel(.ask)
    }

    func askScopes() -> [AskScopeOption] {
        guard let state = app.store.window(windowID), let selected = state.selectedPageID else { return [] }
        var options = [AskScopeOption(scope: .page, label: "This page")]
        if let site = state.site(containing: selected), site.pages.count > 1 {
            options.append(.init(scope: .site, label: "All \(site.name) pages (\(site.pages.count))"))
        }
        if let split = state.split, split.contains(selected) {
            options.append(.init(scope: .split, label: "Compare split"))
        }
        return options
    }

    static func askMessage(for availability: AIAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .turnedOff: return "On-device AI is turned off. Turn it on here or from the Plinth menu."
        case .unavailable(let reason): return reason
        }
    }

    /// The pages a question covers, selected page first.
    static func askPages(scope: AskScope, selected: PageID, window: WindowState) -> [PageID] {
        switch scope {
        case .page: return [selected]
        case .site: return window.site(containing: selected)?.pages.map(\.id) ?? [selected]
        case .split:
            guard let split = window.split else { return [selected] }
            return [split.leading, split.trailing]
        }
    }

    func ask(_ question: String) {
        guard let state = app.store.window(windowID), let selected = state.selectedPageID else { return }
        chrome.askQuestion = question
        let scope = chrome.askScope
        let ids = Self.askPages(scope: scope, selected: selected, window: state)
        app.ai.refreshAvailability()
        if let message = Self.askMessage(for: app.ai.availability) {
            chrome.askMessage = message
            return
        }
        askTask?.cancel()
        chrome.askAnswer = ""
        chrome.askMessage = nil
        chrome.askStreaming = true
        askTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var texts: [PageText] = []
            for id in ids {
                // A page that has never been shown has no browser yet; make one so it can be read.
                if self.app.pool.existing(id) == nil, let page = self.app.store.page(id) {
                    _ = self.app.pool.browser(for: page)
                }
                if let text = await self.app.pool.readableText(for: id) { texts.append(text) }
            }
            var answered = false
            do {
                for try await partial in self.app.ai.ask(question, pages: texts, scope: scope) {
                    if Task.isCancelled { break }
                    self.chrome.askAnswer = partial
                    answered = true
                }
            } catch {
                if !Task.isCancelled { self.chrome.askMessage = error.localizedDescription }
            }
            if answered, !self.isPrivate { self.app.earn(.milestone(.firstAsk)) }
            self.chrome.askStreaming = false
        }
    }

    func stopAsk() {
        askTask?.cancel()
        askTask = nil
        chrome.askStreaming = false
    }
}
