import AppKit

/// The menu bar. Same items and shortcuts as the Mac app where the feature exists here.
@MainActor
enum MainMenu {
    static func build(app: ChromiumApp) -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(main, "Plinth")
        add(appMenu, "About Plinth", #selector(ChromiumApp.menuAbout(_:)), "", target: app)
        add(appMenu, "Show Welcome Guide", #selector(ChromiumApp.menuShowWelcome(_:)), "", target: app)
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(ChromiumApp.menuSettings(_:)), ",", target: app)
        add(appMenu, "Use On-Device AI", #selector(ChromiumApp.menuToggleAI(_:)), "", target: app)
        add(appMenu, "iCloud Sync", #selector(ChromiumApp.menuToggleSync(_:)), "", target: app)
        appMenu.addItem(.separator())
        add(appMenu, "Hide Plinth", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp)
        appMenu.addItem(.separator())
        add(appMenu, "Quit Plinth", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu(main, "File")
        add(file, "New Page", #selector(ChromiumApp.menuNewPage(_:)), "t", target: app)
        add(file, "New Window", #selector(ChromiumApp.menuNewWindow(_:)), "n", target: app)
        add(file, "New Private Window", #selector(ChromiumApp.menuNewPrivateWindow(_:)), "n", [.command, .shift], target: app)
        add(file, "Search or Enter Address…", #selector(ChromiumApp.menuOpenLocation(_:)), "l", target: app)
        file.addItem(.separator())
        add(file, "Close Page", #selector(ChromiumApp.menuClosePage(_:)), "w", target: app)
        add(file, "Close Window", #selector(ChromiumApp.menuCloseWindow(_:)), "w", [.command, .shift], target: app)
        add(file, "Reopen Closed Page", #selector(ChromiumApp.menuReopen(_:)), "t", [.command, .shift], target: app)
        file.addItem(.separator())
        add(file, "Move to Main Window", #selector(ChromiumApp.menuPromoteMini(_:)), "\r", [.command, .shift], target: app)
        let remote = NSMenuItem(title: RemotePagesMenu.title, action: nil, keyEquivalent: "")
        remote.submenu = NSMenu(title: RemotePagesMenu.title)
        remote.submenu?.delegate = app.remotePagesMenu
        file.addItem(remote)

        // Edit items go to the first responder: the page, or a Plinth text field.
        let edit = submenu(main, "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(ChromiumApp.menuFind(_:)), "f", target: app)
        add(edit, "Ask About This Page…", #selector(ChromiumApp.menuAsk(_:)), "j", target: app)

        let view = submenu(main, "View")
        add(view, "Reload Page", #selector(ChromiumApp.menuReload(_:)), "r", target: app)
        view.addItem(.separator())
        add(view, "Zoom In", #selector(ChromiumApp.menuZoomIn(_:)), "+", target: app)
        add(view, "Zoom Out", #selector(ChromiumApp.menuZoomOut(_:)), "-", target: app)
        add(view, "Actual Size", #selector(ChromiumApp.menuZoomReset(_:)), "0", target: app)
        view.addItem(.separator())
        add(view, "Pages in Bottom Dock", #selector(ChromiumApp.menuUseDock(_:)), "", target: app)
        add(view, "Pages in Sidebar", #selector(ChromiumApp.menuUseSidebar(_:)), "", target: app)
        add(view, "Toggle Sidebar", #selector(ChromiumApp.menuToggleSidebar(_:)), "s", [.command, .control], target: app)
        view.addItem(.separator())
        add(view, "Show Shelf", #selector(ChromiumApp.menuShelf(_:)), "l", [.command, .shift], target: app)
        add(view, "Show History", #selector(ChromiumApp.menuHistory(_:)), "y", target: app)
        add(view, "Show Downloads", #selector(ChromiumApp.menuDownloads(_:)), "j", [.command, .option], target: app)
        view.addItem(.separator())
        add(view, "Split View with Next Page", #selector(ChromiumApp.menuSplitWithNext(_:)), "\\", [.command, .option], target: app)
        add(view, "End Split View", #selector(ChromiumApp.menuEndSplit(_:)), "\\", [.command, .shift], target: app)
        view.addItem(.separator())
        add(view, "Developer Tools", #selector(ChromiumApp.menuDevTools(_:)), "i", [.command, .option], target: app)

        let go = submenu(main, "Go")
        add(go, "Back", #selector(ChromiumApp.menuBack(_:)), "[", target: app)
        add(go, "Forward", #selector(ChromiumApp.menuForward(_:)), "]", target: app)
        go.addItem(.separator())
        add(go, "Next Page", #selector(ChromiumApp.menuNextPage(_:)), "]", [.command, .shift], target: app)
        add(go, "Previous Page", #selector(ChromiumApp.menuPreviousPage(_:)), "[", [.command, .shift], target: app)
        go.addItem(.separator())
        for number in 1...9 {
            let item = add(go, "Page \(number)", #selector(ChromiumApp.menuSelectNumbered(_:)), "\(number)", target: app)
            item.tag = number
        }

        let bookmarks = submenu(main, "Bookmarks")
        add(bookmarks, "Bookmark This Page", #selector(ChromiumApp.menuBookmarkPage(_:)), "d", target: app)
        add(bookmarks, "Show Bookmarks", #selector(ChromiumApp.menuShowBookmarks(_:)), "b", [.command, .option], target: app)

        let site = submenu(main, "Site")
        add(site, "Keep on Bar", #selector(ChromiumApp.menuKeepSite(_:)), "k", [.command, .shift], target: app)
        add(site, "Pin Site", #selector(ChromiumApp.menuPinSite(_:)), "p", [.command, .shift], target: app)
        add(site, "Put Away", #selector(ChromiumApp.menuPutAway(_:)), "e", [.command, .shift], target: app)

        let extensions = submenu(main, "Extensions")
        add(extensions, "Manage Extensions", #selector(ChromiumApp.menuManageExtensions(_:)), "", target: app)
        add(extensions, "Get Extensions…", #selector(ChromiumApp.menuGetExtensions(_:)), "", target: app)

        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }
}
