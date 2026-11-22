import AppKit
import SwiftUI
import PlinthModel
import PlinthPanels
import PlinthStore

// Bookmarks, as in the Mac app: ⌘D saves the page and shows its card, ⌥⌘B shows the Bookmarks panel,
// and bookmarks are listed under their own heading in the command bar. They live in `bookmarks.json`
// in this app's storage folder (the shared `BookmarkStore`).

extension ChromiumApp {
    @objc func menuBookmarkPage(_ sender: Any?) { keyController?.bookmarkCurrentPage() }
    @objc func menuShowBookmarks(_ sender: Any?) { keyController?.toggleBookmarks() }
}

extension BrowserWindowController {
    /// ⌘D: saves the current page and shows the card. On a page that is already saved the card offers
    /// to rename, move or remove it; ⌘D again while the card is up closes it.
    func bookmarkCurrentPage() {
        if case .bookmark = chrome.panel { dismissPanel(); return }
        guard let id = app.store.window(windowID)?.selectedPageID, let page = app.store.page(id),
              let added = app.bookmarks.add(title: page.rawTitle.isEmpty ? page.name : page.rawTitle, url: page.url) else {
            NSSound.beep() // no page, or one that is not a web address
            return
        }
        var isNew = false
        if case .added = added { isNew = true }
        showPanel(.bookmark(id: added.bookmark.id, isNew: isNew))
    }

    func toggleBookmarks() {
        if chrome.panel == .bookmarks { dismissPanel() } else { showPanel(.bookmarks) }
    }

    /// Opens a bookmark in a new page, as a history row does.
    func open(_ bookmark: Bookmark) {
        submit(.result(SearchResult(id: SearchResult.bookmarkIDPrefix + bookmark.id.uuidString, target: .history(bookmark.url),
                                    title: bookmark.title, subtitle: bookmark.url.absoluteString,
                                    key: SiteKey(bookmark.url.host(percentEncoded: false) ?? ""))))
    }
}

extension PanelLayer {
    /// The Bookmarks panel.
    func bookmarksPanel(accent: Color) -> some View {
        let store = app.bookmarks!
        return BookmarksView(
            folders: store.folders,
            bookmarks: store.bookmarks,
            accent: accent,
            icon: { app.pool.favicons.image(for: $0) },
            onOpen: { controller.open($0) },
            onRename: { store.rename($0, to: $1) },
            onMove: { store.move($0, to: $1) },
            onRemove: { store.remove($0) },
            onAddFolder: { store.addFolder(named: $0, in: $1).id },
            onRenameFolder: { store.renameFolder($0, to: $1) },
            onMoveFolder: { store.moveFolder($0, to: $1) },
            onRemoveFolder: { store.removeFolder($0) },
            onDismiss: { controller.dismissPanel() }
        )
    }

    /// The card for one bookmark, which closes itself if the bookmark is gone.
    @ViewBuilder
    func bookmarkCard(id: UUID, isNew: Bool, accent: Color) -> some View {
        if let bookmark = app.bookmarks.bookmark(id) {
            BookmarkCardView(
                siteKey: SiteKey(bookmark.url.host(percentEncoded: false) ?? ""),
                title: bookmark.title,
                url: bookmark.url.absoluteString,
                isNew: isNew,
                folders: app.bookmarks.folderChoices(),
                selectedFolder: bookmark.folder,
                accent: accent,
                icon: { app.pool.favicons.image(for: $0) },
                onRename: { app.bookmarks.rename(id, to: $0) },
                onMove: { app.bookmarks.move(id, to: $0) },
                onRemove: {
                    app.bookmarks.remove(id)
                    controller.dismissPanel()
                },
                onDismiss: { controller.dismissPanel() }
            )
        }
    }
}
