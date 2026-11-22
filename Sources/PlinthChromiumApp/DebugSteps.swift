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
/// js <script> · quit
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
                + "window=\(app.keyController.map { NSStringFromRect($0.window.frame) } ?? "-")")
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
        case "settings":
            app.showSettings()
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown step \(command)")
        }
        log("done \(command) \(arg)")
    }
}
