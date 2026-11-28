import AppKit
import PlinthModel
import PlinthFade
import PlinthSidebar

/// Scripted checks without clicking, like the Mac app's PLINTH_STEPS hook. Steps are separated by
/// ";" and log "[steps] …" lines to stdout:
///
///   PLINTH_STEPS="wait 3; open https://example.com; layout sidebar; state; select 1; pin; quit"
///
/// wait <s> · open <url> · nav <url> · select <n> (⌘-number) · pin · unpin · folder · keep · putaway ·
/// split · layout dock|sidebar · collapse · command · shelf · close · extensions · popup <n> · state ·
/// js <script> · readtext · dwell <s> · meaning <query> · restore · card · clickcard · mini <url> · promote · promotekey ·
/// minikey · eval <expr> · zoom [in|out|reset] · setting <name> on|off · private <url> · quit
///
/// Bookmarks, history, import, passwords and sync (DebugFeatureSteps.swift): bookmark · bookmarks · history ·
/// bmstate · historycount · clearhistory · import <browser> · pw add|list|answer|pending|delete|clear … ·
/// pwimport <browser> · pwcsv <file> · pwfocus <css> · pwtype <css> <text> · pwsubmit <css> · pwvalue <css> ·
/// sync · syncon · syncoff · syncpeer · syncnow · shot <png> · settingsat <section>
///
/// The welcome guide and peek (DebugWelcomePeekSteps.swift): welcome [card] · welcomestate · welcomenext ·
/// welcomeback · welcomego <card> · welcomeskip · welcomeimport · welcomekey <key> · peek <url> · peekstate · peekopen ·
/// peekclose · peekfocuspage · key <key> · peekclickout · shiftclick <css>
@MainActor
enum DebugSteps {
    static func runIfRequested(_ app: ChromiumApp) {
        guard let script = ProcessInfo.processInfo.environment["PLINTH_STEPS"] else { return }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            for step in steps {
                let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                await run(parts[0], arg, app)
            }
        }
    }

    static func log(_ text: String) {
        print("[steps] \(text)")
        fflush(stdout)
    }

    private static func run(_ command: String, _ arg: String, _ app: ChromiumApp) async {
        let store = app.store!
        guard let wid = app.keyWindowID ?? store.windows.first?.id else { log("no window"); return }
        let window = { store.window(wid) }
        let selectedSite = { window()?.selectedPageID.flatMap { window()?.site(containing: $0) } }
        switch command {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        case "open":
            if let url = URL(string: arg) { store.openPage(url: url, in: wid) }
        case "nav":
            if let url = URL(string: arg), let page = window()?.selectedPageID { store.navigate(page, to: url) }
        case "select":
            store.selectByShortcut(Int(arg) ?? 1, in: wid)
        case "pin":
            if let site = selectedSite() { store.pin(site: site.id) }
        case "unpin":
            if let pin = store.pins.first { store.unpin(pin.id, into: wid) }
        case "folder":
            // Puts the first two pins into a new folder.
            if store.pins.count >= 2 { app.handle(.groupPins(store.pins[1].id, onto: store.pins[0].id), in: wid) }
        case "keep":
            if let site = selectedSite() { store.setKept(site.id, true) }
        case "putaway":
            if let site = selectedSite() { store.shelve(site: site.id) }
        case "split":
            app.menuSplitWithNext(nil)
        case "layout":
            if let layout = TabLayout(rawValue: arg) { app.prefs.update { $0.tabLayout = layout } }
        case "collapse":
            app.prefs.update { $0.sidebarCollapsed.toggle() }
        case "command":
            app.keyController?.openCommandBar(newPage: true)
        case "shelf":
            app.keyController?.toggleShelf()
        case "divider":
            // divider <x>: drags the split divider to x points from the window's left edge.
            if let x = Double(arg), let c = app.keyController { c.dragSplitDivider(to: x); c.endSplitDividerDrag() }
        case "dismiss":
            app.keyController?.dismissPanel()
        case "size":
            // size <width> <height>: the key window's size in points, centred on its screen.
            let wh = arg.split(separator: " ").compactMap { Double($0) }
            if wh.count == 2, let w = app.keyController?.window {
                w.setContentSize(NSSize(width: wh[0], height: wh[1]))
                w.center()
            }
        case "clearshelf":
            app.clearShelf()
        case "undoshelf":
            app.undoClearShelf()
        case "ask":
            app.keyController?.openAsk()
            if !arg.isEmpty { app.keyController?.ask(arg) }
        case "close":
            app.keyController?.dismissPanel()
        case "extensions":
            app.extensions.refresh()
            log("extensions: " + app.extensions.installed.map { "\($0.name) [\($0.id)] popup=\($0.popupURL?.absoluteString ?? "-")" }.joined(separator: " | "))
        case "popup":
            let index = (Int(arg) ?? 1) - 1
            app.extensions.refresh()
            guard let controller = app.keyController, app.extensions.installed.indices.contains(index) else { log("no such extension"); return }
            let frame = controller.window.frame
            app.extensions.openPopup(app.extensions.installed[index], from: controller.window,
                                     anchor: NSRect(x: frame.maxX - 60, y: frame.maxY - 34, width: 28, height: 28))
        case "js":
            if let page = window()?.selectedPageID { app.pool.existing(page)?.executeJavaScript(arg) }
        case "state":
            let w = window()
            let sites = (w?.sites ?? []).map { site in "\(site.name)(\(site.pages.map(\.name).joined(separator: ",")))\(site.isKept ? "*" : "")" }
            let pins = store.pins.map { $0.name + ($0.folder.map { "@" + $0.name } ?? "") }
            let selected = w?.selectedPageID.flatMap { store.page($0) }
            let browser = w?.selectedPageID.flatMap { app.pool.existing($0) }
            log("layout=\(app.prefs.value.tabLayout.rawValue) pins=\(pins) sites=\(sites) shelf=\(store.shelf.count) "
                + "selected=\(selected?.name ?? "-") url=\(selected?.url.absoluteString ?? "-") "
                + "title=\(browser?.title ?? "-") hostAttached=\(browser?.hostWindow?.parent != nil) "
                + "window=\(app.keyController.map { NSStringFromRect($0.window.frame) } ?? "-") "
                + "ai=\(app.ai.availability) minis=\(app.miniWindows.map { $0.browser?.address ?? "-" })")
        case "geom":
            if let c = app.keyController {
                log("parent \(NSStringFromRect(c.window.frame)) content \(NSStringFromRect(c.window.contentView?.frame ?? .zero)) attached \(c.chrome.attached.values.map { NSStringFromRect(c.window.convertToScreen($0)) })")
            }
            if let c = app.keyController {
                log("overlay \(NSStringFromRect(c.overlay.frame)) content \(NSStringFromRect(c.overlay.contentView?.frame ?? .zero)) ignores=\(c.overlay.ignoresMouseEvents) children=\(c.window.childWindows?.map { String(describing: type(of: $0)) } ?? [])")
            }
            for w in NSApp.windows where w.isVisible {
                log("window \(type(of: w)) \(NSStringFromRect(w.frame)) parent=\(w.parent != nil) level=\(w.level.rawValue) style=\(w.styleMask.rawValue) shadow=\(w.hasShadow) opaque=\(w.isOpaque) content=\(NSStringFromRect(w.contentView?.frame ?? .zero))")
            }
        case "flyout":
            app.keyController?.openFlyout()
        case "unflyout":
            app.keyController?.closeFlyout(after: 0)
        case "listfolder":
            if let folder = store.pins.compactMap(\.folder).first { app.prefs.update { $0.listFolders.insert(folder.id) } }
        case "downloads":
            app.keyController?.toggleDownloads()
            log("downloads: " + app.downloads.list.items.map { "\($0.filename) \($0.state)" }.joined(separator: ", "))
        case "fadenow":
            // Makes every page old enough to fade, then runs fading: checks auto-shelving end to end.
            store.setFader(FadeEngine(policy: FadePolicy(siteBaseLifetime: 2, siteLifetimePerExtraDay: 1, siteMaxLifetime: 4, pageBaseLifetime: 2, pageMaxLifetime: 4, minFadingDuration: 0.5)))
            app.scheduleFade()
            log("after fade: shelf=\(store.shelf.map { "\($0.name)(\($0.pages.count))" }) sites=\(store.window(wid)?.sites.map(\.name) ?? []) fading=\(store.window(wid)?.sites.filter { $0.fade == .fading }.map(\.name) ?? [])")
        case "group":
            // A group of the window's first two sites, as if its suggestion was accepted.
            if let sites = window()?.sites, sites.count >= 2 {
                let id = store.acceptSuggestion(GroupSuggestion(window: wid, keys: [sites[0].key, sites[1].key],
                                                                siteNames: [sites[0].name, sites[1].name]))
                log("group \(store.group(id)?.name ?? "-")")
            }
        case "popupjs":
            app.extensions.runInPopup(arg)
        case "windows":
            for w in NSApp.windows where w.isVisible {
                log("window \(type(of: w)) id=\(w.identifier?.rawValue ?? "-") \(NSStringFromRect(w.frame)) child=\(w.parent != nil)")
            }
        case "about":
            app.menuAbout(nil)
        case "settings":
            app.showSettings()
        case "videos":
            log("videos: \(app.nativeVideo.debugState)")
        case "eval":
            // eval <expression>: logs the result (strings, numbers, JSON-able values) from the selected page.
            guard let page = window()?.selectedPageID, let b = app.pool.existing(page) else { log("eval: no page"); return }
            let value: Any? = await withCheckedContinuation { done in b.evaluateJavaScript(arg) { done.resume(returning: $0) } }
            log("eval: \(value.map { String(describing: $0) } ?? "nil")")
        case "readtext":
            // The selected page's readable text, as semantic history and the resume card get it (lengths only).
            guard let page = window()?.selectedPageID else { log("readtext: no page"); return }
            if let text = await app.pool.readableText(for: page) {
                log("readtext: title=\(text.title) chars=\(text.text.count) focus=\(text.focusExcerpt?.count ?? -1) "
                    + "scroll=\(text.scrollFraction.map { String(format: "%.2f", $0) } ?? "-") start=\(text.text.prefix(80).replacingOccurrences(of: "\n", with: " / "))")
            } else {
                log("readtext: nil")
            }
        case "dwell":
            // Pretend the visible pages have been read for a while, then index them.
            for page in window()?.visiblePageIDs ?? [] {
                store.recordDwell(page, seconds: Double(arg) ?? 40)
                app.indexForMeaningIfNeeded(page)
            }
            log("dwell: ai=\(app.ai.availability) indexed=\(app.indexedHistory.count)")
        case "meaning":
            let raw = await app.ai.semanticSearch(arg, limit: 8)
            log("raw '\(arg)': " + raw.map { "\($0.title)=\(String(format: "%.2f", $0.score))" }.joined(separator: ", "))
            let results = await app.semanticResults(for: arg)
            log("meaning '\(arg)': " + results.map { "\($0.title) [\($0.byMeaning)]" }.joined(separator: " | "))
        case "restore":
            // Brings the newest shelf entry back, as the shelf's Restore does.
            guard let entry = store.shelf.first, let controller = app.controller(for: wid) else { log("restore: shelf empty"); return }
            let ids = store.restore(entry: entry.id, page: nil, into: wid)
            controller.refreshContent()
            controller.showResumeCard(forRestored: ids)
            log("restore: \(entry.name) pages=\(ids.count)")
        case "card":
            guard let controller = app.controller(for: wid) else { return }
            let card = controller.chrome.resumeCard
            let w = controller.resumeCardWindow
            let children = controller.window.childWindows ?? []
            let order = children.map { $0 === controller.overlay ? "overlay" : ($0 === w ? "card" : "page") }
            var topmost = "-"
            if let w, w.isVisible {
                let point = NSPoint(x: w.frame.maxX - 43, y: w.frame.maxY - 37)
                let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                topmost = number == w.windowNumber ? "card" : number == controller.overlay.windowNumber ? "overlay" : "\(number)"
            }
            log("card: page=\(card.flatMap { store.page($0.page)?.name } ?? "-") loading=\(card?.isLoading ?? false) "
                + "summary=\(card?.summary ?? "-") window=\(w.map { NSStringFromRect($0.frame) } ?? "-") visible=\(w?.isVisible ?? false) "
                + "children=\(order) overlayIgnoresMouse=\(controller.overlay.ignoresMouseEvents) topmostAtClose=\(topmost)")
        case "clickcard":
            // A mouse click on the card's × through AppKit (the window's own event path, not the window server's).
            guard let w = app.controller(for: wid)?.resumeCardWindow, w.isVisible else { log("clickcard: no card"); return }
            let point = NSPoint(x: w.frame.width - 43, y: w.frame.height - 37)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    w.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            log("clickcard: card now \(app.controller(for: wid)?.chrome.resumeCard == nil ? "dismissed" : "still showing")")
        case "mini":
            if let url = URL(string: arg) { app.openFromOtherApp(url) }
            log("mini: \(app.miniWindows.count) open")
        case "minikey":
            // Makes the first mini window key, as if clicked.
            app.miniWindows.first?.window.makeKeyAndOrderFront(nil)
        case "promotekey":
            // ⇧⌘↩ through the menu bar, as a key press in the mini window's page would send it.
            let window = app.keyMiniWindow?.window
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                log("promotekey: keyMini=\(window != nil) handled=\(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false) minis=\(app.miniWindows.count)")
            }
        case "promote":
            // ⇧⌘↩ on the mini window in front (or the first one).
            guard let mini = app.keyMiniWindow ?? app.miniWindows.first else { log("promote: no mini window"); return }
            let browser = mini.browser
            app.promote(mini)
            let page = window()?.selectedPageID
            let kept = page.flatMap { app.pool.existing($0) } === browser
            log("promote: minis=\(app.miniWindows.count) selected=\(page.flatMap { store.page($0)?.url.absoluteString } ?? "-") sameBrowser=\(kept)")
        case "quit":
            NSApp.terminate(nil)
        default:
            if await !runFeature(command, arg, app) { log("unknown step \(command)") }
        }
        log("done \(command) \(arg)")
    }
}
