import PlinthModel
import PlinthStore

/// Back, forward, reload and stop for a page (the CEF page pool in the app, a fake in tests).
@MainActor
public protocol PageNavigating: AnyObject {
    func goBack(_ page: PageID)
    func goForward(_ page: PageID)
    func reload(_ page: PageID)
    func stopLoading(_ page: PageID)
}

/// The window's own panels.
@MainActor
public protocol WindowPanels: AnyObject {
    /// No panel (command bar, shelf, find) is open.
    var hasNoPanel: Bool { get }
    func openCommandBar(newPage: Bool)
    func toggleShelf()
    func toggleDownloads()
}

/// Turns what the bar or the sidebar asked for into store changes, exactly as the Mac app's
/// `AppController.handle(_:in:)` does, so both layouts and both apps behave the same.
@MainActor
public enum ActionRouter {
    public static func handle(_ action: BarAction, in windowID: WindowID, store: BrowserStore,
                              pages: PageNavigating, panels: WindowPanels) {
        let selected = store.window(windowID)?.selectedPageID
        switch action {
        case .selectPage(let id):
            // Clicking the page you are already on opens the address editor with its URL selected.
            if selected == id, panels.hasNoPanel {
                panels.openCommandBar(newPage: false)
            } else {
                store.select(id, in: windowID)
            }
        case .closePage(let id): store.closePage(id)
        case .selectPin(let id):
            if let pin = store.pins.first(where: { $0.id == id }), selected == pin.page.id, panels.hasNoPanel {
                panels.openCommandBar(newPage: false)
            } else {
                store.selectPin(id, in: windowID)
            }
        case .selectSite(let id): store.selectSite(id, in: windowID)
        case .toggleFold(let id): store.toggleFold(id, in: windowID)
        case .newPage: panels.openCommandBar(newPage: true)
        case .goBack: if let selected { pages.goBack(selected) }
        case .goForward: if let selected { pages.goForward(selected) }
        case .reload: if let selected { pages.reload(selected) }
        case .stopLoading: if let selected { pages.stopLoading(selected) }
        case .openCommandBar: panels.openCommandBar(newPage: false)
        case .openShelf: panels.toggleShelf()
        case .openDownloads: panels.toggleDownloads()
        case .setKept(let id, let kept): store.setKept(id, kept)
        case .pinSite(let id): store.pin(site: id)
        case .unpin(let id): store.unpin(id, into: windowID)
        case .movePinToFolder(let id, let folder):
            if let folder { store.movePin(id, toFolder: folder) } else { store.createPinFolder(with: id) }
        case .groupPins(let id, let other): store.groupPins(id, onto: other)
        case .removePinFromFolder(let id): store.removePinFromFolder(id)
        case .renamePinFolder(let id, let name): store.renamePinFolder(id, to: name)
        case .ungroupPinFolder(let id): store.ungroupPinFolder(id)
        case .resetPin(let id): store.resetPin(id)
        case .shelveSite(let id): store.shelve(site: id)
        case .closeSite(let id): store.closeSite(id)
        case .renamePage(let id, let name): store.rename(id, to: name)
        case .splitWithCurrent(let id):
            if let selected, selected != id { store.split(selected, with: id, in: windowID) }
        case .endSplit: store.endSplit(in: windowID)
        case .moveSite(let id, let index):
            store.moveSite(id, toIndex: realSiteIndex(index, moving: id, in: windowID, store: store), in: windowID)
        case .movePage(let id, let index): store.movePage(id, toIndex: index)
        case .splitPages(let dragged, let target):
            if dragged != target { store.split(target, with: dragged, in: windowID) }
        }
    }

    /// The bar and sidebar count only visible sites when a group is focused; the store counts all of them.
    static func realSiteIndex(_ visibleIndex: Int, moving id: SiteID, in windowID: WindowID, store: BrowserStore) -> Int {
        guard let all = store.window(windowID)?.sites else { return visibleIndex }
        let visible = store.visibleSites(in: windowID).filter { $0.id != id }
        let rest = all.filter { $0.id != id }
        guard visible.count != rest.count else { return visibleIndex }
        if visibleIndex < visible.count, let at = rest.firstIndex(where: { $0.id == visible[visibleIndex].id }) { return at }
        if let last = visible.last, let at = rest.firstIndex(where: { $0.id == last.id }) { return at + 1 }
        return visibleIndex
    }
}
