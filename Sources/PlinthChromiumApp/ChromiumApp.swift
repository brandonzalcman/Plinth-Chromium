import AppKit
import Observation
import SwiftUI
import PlinthAI
import PlinthCEF
import PlinthExtensions
import PlinthFade
import PlinthLayout
import PlinthModel
import PlinthRules
import PlinthSettings
import PlinthSidebar
import PlinthStore
import PlinthSync

/// Owns the store, the page pool and the windows, and connects them. One per process.
/// The Chromium counterpart of the Mac app's `AppController`: same store, same rules, same actions.
@MainActor
@Observable
public final class ChromiumApp: NSObject, NSApplicationDelegate {
    public private(set) static var shared: ChromiumApp!

    @ObservationIgnored let identity = SiteIdentity()
    @ObservationIgnored var resolver = AddressResolver()
    @ObservationIgnored let layoutEngine = BarLayoutEngine()
    @ObservationIgnored lazy var pinPolicy = PinLinkPolicy(identity: identity)
    @ObservationIgnored private(set) var settings: SettingsStore!
    @ObservationIgnored private(set) var prefs: ShellPreferencesStore!
    @ObservationIgnored private(set) var store: BrowserStore!
    /// Bookmarks and their folders (see Bookmarks.swift).
    @ObservationIgnored private(set) var bookmarks: BookmarkStore!
    /// Plinth's own password manager (see Passwords/PasswordsController.swift).
    @ObservationIgnored var passwords: PasswordsController!
    /// iCloud sync, while it is on (see Sync.swift).
    @ObservationIgnored var sync: SyncCoordinator?
    /// The in-memory server a scratch profile syncs with (`PLINTH_SYNC=memory`), for checking the wiring.
    @ObservationIgnored var memorySyncTransport: InMemoryTransport?
    /// Open pages on the user's other devices, from the last sync.
    var otherDevices: [DeviceOpenPages] = []
    /// A scratch profile's sync switch, never saved (PLINTH_SYNC=memory starts it on).
    @ObservationIgnored var scratchSyncSwitch = ProcessInfo.processInfo.environment["PLINTH_SYNC"] == "memory"
    /// Fills "Pages on Other Devices" when it opens.
    @ObservationIgnored lazy var remotePagesMenu = RemotePagesMenu(app: self)
    @ObservationIgnored private(set) var pool: PagePool!
    @ObservationIgnored private(set) var extensions: ExtensionsController!
    @ObservationIgnored private(set) var downloads: DownloadsModel!
    @ObservationIgnored private(set) var storageDirectory: URL!
    @ObservationIgnored var settingsWindow: NSWindow?
    @ObservationIgnored var aboutWindow: NSWindow?
    /// Points and levels (see Loyalty.swift).
    @ObservationIgnored var loyalty: LoyaltyController!
    /// On-device AI: resume card summaries and semantic history (see SemanticHistory.swift).
    @ObservationIgnored var ai: AIService!
    /// History entries already sent to the semantic index this run.
    @ObservationIgnored var indexedHistory = Set<UUID>()
    /// Windows for links from other apps (see MiniWindow.swift).
    @ObservationIgnored var miniWindows: [MiniWindowController] = []
    /// The welcome guide, while it is open (see Welcome/WelcomeWindow.swift).
    @ObservationIgnored var welcome: WelcomeWindowController?

    /// Bumped whenever a page's loading state changes, so the chrome redraws its buttons and progress.
    var loadingTick = 0
    /// The accent choice, observed so the chrome follows a change in Settings.
    var accentChoice = AccentChoice.blue

    @ObservationIgnored private var controllers: [WindowID: BrowserWindowController] = [:]
    @ObservationIgnored private var privateProfiles: [WindowID: PCEFProfile] = [:]
    @ObservationIgnored private var lastMainWindowID: WindowID?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var dwellTimer: Timer?
    @ObservationIgnored private let dwellInterval: TimeInterval = 5
    @ObservationIgnored private var pendingOpenURLs: [URL] = []
    @ObservationIgnored private var didFinishLaunching = false
    /// Quit has begun: every page's browser is closing, and none may be made again.
    @ObservationIgnored private(set) var isTerminating = false

    // MARK: Entry point

    /// Starts Chromium and runs the app. Called from the executable's main.swift.
    public static func main() {
        let application = PCEFApplication.shared as! PCEFApplication
        Brand.registerFonts()
        let env = ProcessInfo.processInfo.environment
        let support = Self.storageDirectory(env)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let paths = env["PLINTH_LOAD_EXTENSION"] {
            PCEFRuntime.unpackedExtensions = paths.split(separator: ",").map(String.init)
        }
        // Plinth's password script runs in every page from the start (see ChromiumPasswordScript.swift).
        PCEFRuntime.passwordScript = ChromiumPasswordScript.source
        PCEFRuntime.passwordScriptTestMode = env["PLINTH_STORAGE"] != nil && env["PLINTH_STEPS"] != nil
        let cefRoot = support.appendingPathComponent("Chromium", isDirectory: true).path
        // Plinth keeps its own session (state.json). Chromium's would reopen its windows behind Plinth's.
        try? FileManager.default.removeItem(atPath: cefRoot + "/Default/Sessions")
        // Test profiles (PLINTH_STORAGE) skip the Keychain prompt for Chromium's cookie key.
        guard PCEFRuntime.start(withCachePath: cefRoot, mockKeychain: env["PLINTH_STORAGE"] != nil) else {
            let alert = NSAlert()
            alert.messageText = "Plinth couldn’t start Chromium."
            alert.informativeText = "The Chromium Embedded Framework is missing or damaged. Reinstall Plinth."
            alert.runModal()
            exit(1)
        }
        let app = ChromiumApp(storage: support)
        shared = app
        application.delegate = app
        application.terminateHandler = { [weak app] in app?.terminate() }
        PCEFRuntime.strayBrowserHandler = { url in
            MainActor.assumeIsolated {
                guard let app = ChromiumApp.shared, app.store != nil, let target = URL(string: url) else { return }
                app.openInNewPage(target)
            }
        }
        PCEFRuntime.runMessageLoop()
        PCEFRuntime.log("message loop ended")
        if !PCEFRuntime.loopWasForcedToStop { PCEFRuntime.shutdown() }
        exit(0)
    }

    static func storageDirectory(_ env: [String: String]) -> URL {
        if let path = env["PLINTH_STORAGE"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plinth Chromium", isDirectory: true)
    }

    init(storage: URL) {
        storageDirectory = storage
        super.init()
    }

    /// The Chromium profile folder for the shared profile (extensions live here).
    var chromiumProfileDirectory: URL { storageDirectory.appendingPathComponent("Chromium/Default", isDirectory: true) }

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        settings = SettingsStore(storageDirectory: storageDirectory)
        prefs = ShellPreferencesStore(directory: storageDirectory)
        if let layout = env["PLINTH_LAYOUT"].flatMap(TabLayout.init(rawValue:)) { prefs.update { $0.tabLayout = layout } }
        NSApp.appearance = Self.appearance(settings.value.appearance)
        resolver.engine = settings.value.searchEngine
        accentChoice = settings.value.accent
        store = BrowserStore(identity: identity, namer: PageNamer(), fader: Self.fader(for: settings.value.fadeBehavior),
                             storageDirectory: storageDirectory)
        bookmarks = BookmarkStore(storageDirectory: storageDirectory)
        pool = PagePool(siteKey: { [identity] in identity.key(for: $0) })
        pool.favicons.cacheDirectory = storageDirectory.appendingPathComponent("Favicons", isDirectory: true)
        extensions = ExtensionsController(app: self, profileDirectory: chromiumProfileDirectory)
        downloads = DownloadsModel()
        // A page opened straight onto a file has nothing to show once the file is down: close it then
        // (closing it sooner stops the download), or it would fetch the file again every time it is restored.
        downloads.onStopped = { [weak self] url in
            guard let self else { return }
            for window in self.store.windows {
                for site in window.sites {
                    for page in site.pages where page.url == url && !self.pool.canGoBack(page.id) {
                        self.store.closePage(page.id)
                    }
                }
            }
        }
        if let folder = env["PLINTH_DOWNLOADS"] ?? settings.value.downloadFolder, !folder.isEmpty {
            PCEFRuntime.downloadsDirectory = folder
        }
        downloads.opensSafeFiles = { [weak self] in self?.settings.value.openSafeFilesAfterDownload ?? false }
        applyChromiumSettings(settings.value, previous: nil)
        connect()
        setUpPasswords()
        setUpLoyalty()
        setUpAI()
        settings.observe { [weak self] old, new in self?.settingsDidChange(from: old, to: new) }
        prefs.observe { [weak self] old, new in
            guard let self, old.tabLayout != new.tabLayout || old.sidebarCollapsed != new.sidebarCollapsed else { return }
            for c in self.controllers.values { c.refreshContent() }
        }
        NSApp.mainMenu = MainMenu.build(app: self)

        scheduleFade()
        // A profile with no windows yet is a new one: it gets the welcome guide.
        let profileHadWindows = !store.windows.isEmpty
        if store.windows.isEmpty { store.createWindow() }
        if let list = env["PLINTH_OPEN"], let first = store.windows.first?.id {
            for text in list.split(separator: ",") {
                if let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { store.openPage(url: url, in: first) }
            }
        }
        for window in store.windows where !window.isPrivate { showController(for: window.id) }
        NSApp.activate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordDwell() }
        }
        didFinishLaunching = true
        startSyncIfConfigured()
        let early = pendingOpenURLs
        pendingOpenURLs = []
        for url in early { openFromOtherApp(url) }
        launchWelcomeIfNeeded(profileHadWindows: profileHadWindows)
        DebugSteps.runIfRequested(self)
    }

    static func fader(for behavior: FadeBehavior) -> FadeEngine {
        FadeEngine(policy: FadePolicy.standard.scaled(by: behavior.lifetimeScale))
    }

    static func appearance(_ choice: AppearanceChoice) -> NSAppearance? {
        switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// A brand colour the current level has not unlocked falls back to blue, as on the Mac.
    func accent(_ scheme: ColorScheme) -> Color {
        let choice = accentChoice.effective(atLevel: loyaltyLevel)
        let c = choice.rgb
        // The deepest brand colours lift a little on a dark surface so the current page still reads.
        let lift = scheme == .dark && (choice == .midnight || choice == .mono) ? 0.35 : 0
        func mix(_ v: Double) -> Double { v / 255 + (1 - v / 255) * lift }
        return Color(red: mix(c.r), green: mix(c.g), blue: mix(c.b))
    }

    private func settingsDidChange(from old: AppSettings, to new: AppSettings) {
        if old.searchEngine != new.searchEngine { resolver.engine = new.searchEngine }
        if old.appearance != new.appearance { NSApp.appearance = Self.appearance(new.appearance) }
        if old.accent != new.accent { accentChoice = new.accent }
        applyAISettings(new)
        applyChromiumSettings(new, previous: old)
        if old.fadeBehavior != new.fadeBehavior {
            store.setFader(Self.fader(for: new.fadeBehavior))
            scheduleFade()
        }
    }

    /// Privacy, page and download settings that Chromium carries out. `previous` is nil at launch.
    private func applyChromiumSettings(_ new: AppSettings, previous old: AppSettings?) {
        if old.map({ ChromiumPreferences.differ($0, new) }) ?? true {
            ChromiumPreferences.apply(new, to: .shared)
            for profile in privateProfiles.values { ChromiumPreferences.apply(new, to: profile) }
        }
        pool.defaultZoomLevel = ChromiumPreferences.zoomLevel(forFactor: new.defaultZoom)
        PCEFRuntime.globalPrivacyControl = new.globalPrivacyControl
        PCEFRuntime.saveLocationChooser = new.askWhereToSave ? { suggested, decide in
            MainActor.assumeIsolated { DownloadsModel.chooseSaveLocation(suggested: suggested, decide: decide) }
        } : nil
        if let old, old.downloadFolder != new.downloadFolder, ProcessInfo.processInfo.environment["PLINTH_DOWNLOADS"] == nil {
            PCEFRuntime.downloadsDirectory = new.downloadFolder.flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let existing = store.windows.first(where: { controllers[$0.id] == nil && !$0.isPrivate }) {
                showController(for: existing.id)
            } else {
                newWindow()
            }
        }
        return true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        guard store != nil else { return }
        scheduleFade()
        loyaltyDidBecomeActive()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else { pendingOpenURLs.append(contentsOf: urls); return }
        urls.forEach(openFromOtherApp)
    }

    /// Quit: save, close every page, and let Chromium wind down before the process exits.
    func terminate() {
        PCEFRuntime.log("terminate: \(pool.allBrowsers.count) pages open")
        isTerminating = true
        for c in controllers.values { c.closePeek() }
        for c in controllers.values { c.saveFrame() }
        store.flush()
        bookmarks.flush()
        ShareCard.removeLeftovers()
        extensions.closePopup()
        flushAI()
        for mini in miniWindows { mini.closeBrowser() }
        // Closing for quit keeps every page in the store for next launch.
        pool.closeAll()
        PCEFRuntime.quitAfterBrowsersClose()
    }

    // MARK: Store <-> pages

    private func connect() {
        store.onEvent = { [weak self] event in self?.handle(event) }
        pool.profileForPage = { [weak self] id in
            guard let self, let window = self.store.windowID(containing: id), self.store.isPrivate(window: window) else {
                return .shared
            }
            if let profile = self.privateProfiles[window] { return profile }
            let profile = PCEFProfile.makePrivate()
            ChromiumPreferences.apply(self.settings.value, to: profile)
            self.privateProfiles[window] = profile
            return profile
        }
        pool.callbacks.didUpdate = { [weak self] id, url, title in
            self?.store.pageDidUpdate(id, url: url, title: title, siteNameHint: nil)
        }
        pool.callbacks.openRequest = { [weak self] url, opener, background in
            guard let self, let window = self.store.windowID(containing: opener) ?? self.windowShowing(opener) ?? self.keyWindowID
            else { return }
            self.store.openPage(url: url, in: window, select: !background, opener: opener)
        }
        pool.callbacks.peekRequest = { [weak self] url, opener in
            guard let self, let window = self.windowShowing(opener) ?? self.keyWindowID else { return }
            self.controllers[window]?.showPeek(url)
        }
        pool.callbacks.shouldNavigate = { [weak self] id, url, linkClick in
            guard let self else { return true }
            // A link clicked inside a pin that leaves the pin's site opens as an ordinary page.
            guard linkClick, let pin = self.store.pins.first(where: { $0.page.id == id }),
                  let source = self.store.page(id)?.url,
                  self.pinPolicy.shouldDivert(NavigationRequest(url: url, kind: .linkClick, sourceURL: source), pinKey: pin.key)
            else { return true }
            if let window = self.windowShowing(id) ?? self.keyWindowID {
                self.store.openPage(url: url, in: window, select: true, opener: nil)
            }
            return false
        }
        pool.callbacks.loadingChanged = { [weak self] _ in self?.loadingTick &+= 1 }
        pool.callbacks.fullscreenChanged = { [weak self] id, fullscreen in
            guard let self, let window = self.windowShowing(id) else { return }
            self.controllers[window]?.setChromeHidden(fullscreen)
        }
        pool.callbacks.didClose = { [weak self] id in self?.store.closePage(id) }
        pool.callbacks.hostReady = { [weak self] id in
            for c in self?.controllers.values ?? [:].values { c.hostReady(id) }
        }
        pool.callbacks.activated = { [weak self] id in
            if let window = self?.windowShowing(id) { self?.lastMainWindowID = window }
        }
        pool.callbacks.keyEquivalent = { event in NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false }
        pool.callbacks.passwordMessage = { [weak self] page, browser, message in
            self?.passwords.handle(message, from: page, browser: browser)
        }
    }

    /// The window whose bar shows this page right now (pins appear in every window).
    func windowShowing(_ page: PageID) -> WindowID? {
        if let id = store.windowID(containing: page) { return id }
        return controllers.first { $0.value.shown.contains(page) }?.key
    }

    private func handle(_ event: StoreEvent) {
        switch event {
        case .pageOpened(let id, _):
            // Pages opened in the background start loading straight away, as on the Mac.
            if let page = store.page(id) { pool.browser(for: page) }
        case .pageClosed(let id):
            pool.close(id)
            passwords.pageClosed(id)
        case .pagesShelved(let ids, let key):
            pool.close(ids)
            // Say where they went: pages that faded away should never just vanish.
            let name = store.shelf.first { $0.key == key }?.name ?? key.host
            let text = ids.count == 1 ? "\(name) put away on the shelf" : "\(ids.count) \(name) pages put away on the shelf"
            for c in controllers.values where !store.isPrivate(window: c.windowID) { c.showNotice(text) }
        case .pagesRestored(let ids, _):
            for id in ids { if let page = store.page(id) { pool.browser(for: page) } }
        case .selectionChanged(let window):
            controllers[window]?.refreshContent()
        case .navigate(let id, let url):
            if let page = store.page(id) {
                let existed = pool.existing(id) != nil
                pool.browser(for: page)
                if existed { pool.load(url, in: id) }
            }
        }
    }

    // MARK: Windows

    var keyWindowID: WindowID? {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow {
            let top = key.parent ?? key
            if let match = controllers.first(where: { $0.value.window === top }) { return match.key }
        }
        if let last = lastMainWindowID, controllers[last] != nil { return last }
        return controllers.keys.first
    }

    var keyController: BrowserWindowController? { keyWindowID.flatMap { controllers[$0] } }
    func controller(for id: WindowID) -> BrowserWindowController? { controllers[id] }
    var allControllers: [BrowserWindowController] { Array(controllers.values) }

    func mainWindowBecameKey(_ id: WindowID) { lastMainWindowID = id }

    func showController(for id: WindowID) {
        if let existing = controllers[id] { existing.window.makeKeyAndOrderFront(nil); return }
        let controller = BrowserWindowController(app: self, windowID: id)
        controllers[id] = controller
        controller.window.makeKeyAndOrderFront(nil)
        if store.window(id)?.selectedPageID == nil { controller.openCommandBar(newPage: true) }
    }

    func newWindow(isPrivate: Bool = false) {
        showController(for: store.createWindow(isPrivate: isPrivate))
    }

    /// Closing the last window keeps its bar for next time; closing one of several puts its sites away.
    /// A private window is always discarded, with its in-memory Chromium profile.
    func windowDidClose(_ id: WindowID) {
        controllers[id] = nil
        if store.isPrivate(window: id) {
            let pages = store.window(id)?.sites.flatMap { $0.pages.map(\.id) } ?? []
            store.closeWindow(id)
            pool.close(pages)
            privateProfiles[id] = nil
        } else if controllers.keys.contains(where: { !store.isPrivate(window: $0) }) {
            store.closeWindow(id)
        }
    }

    func openInNewPage(_ url: URL, in window: WindowID? = nil) {
        guard let id = window ?? keyWindowID else { return }
        store.openPage(url: url, in: id, select: true, opener: nil)
    }

    // MARK: Timers

    func scheduleFade() {
        fadeTimer?.invalidate()
        let next = store.runFade()
        let delay = min(max((next ?? .distantFuture).timeIntervalSinceNow, 30), 15 * 60)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFade() }
        }
    }

    private func recordDwell() {
        guard NSApp.isActive else { return }
        store.noteCoOpen(seconds: dwellInterval)
        loyaltyTick()
        guard let id = keyWindowID, let window = store.window(id) else { return }
        for page in window.visiblePageIDs {
            store.recordDwell(page, seconds: dwellInterval)
            indexForMeaningIfNeeded(page)
        }
    }

    // MARK: Bar and sidebar actions

    func handle(_ action: BarAction, in windowID: WindowID) {
        guard let controller = controllers[windowID] else { return }
        ActionRouter.handle(action, in: windowID, store: store, pages: pool, panels: controller)
        controller.refreshContent()
    }

    // MARK: Menu actions

    private func withSelectedPage(_ body: (PageID) -> Void) {
        // A mini window in front has no page in the store; never reach through to a main window behind it.
        guard keyMiniWindow == nil, let id = keyWindowID, let page = store.window(id)?.selectedPageID else { return }
        body(page)
    }

    private func withSelectedSite(_ body: (SiteID) -> Void) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID,
              let site = window.site(containing: page) else { return }
        body(site.id)
    }

    @objc func menuSettings(_ sender: Any?) { showSettings() }
    @objc func menuNewWindow(_ sender: Any?) { newWindow() }
    @objc func menuNewPrivateWindow(_ sender: Any?) { newWindow(isPrivate: true) }
    @objc func menuNewPage(_ sender: Any?) { keyController?.openCommandBar(newPage: true) }
    @objc func menuOpenLocation(_ sender: Any?) { keyController?.openCommandBar(newPage: false) }
    @objc func menuShelf(_ sender: Any?) { keyController?.toggleShelf() }
    @objc func menuFind(_ sender: Any?) { keyController?.openFind() }
    @objc func menuClosePage(_ sender: Any?) {
        if let mini = keyMiniWindow { mini.window.performClose(nil); return }
        guard let id = keyWindowID, let controller = controllers[id] else { NSApp.keyWindow?.performClose(nil); return }
        if controller.dismissPanel() || controller.closePeek() { return }
        if let page = store.window(id)?.selectedPageID, store.window(id)?.page(page) != nil {
            ActionRouter.closePage(page, in: id, store: store)
        } else {
            controller.window.performClose(nil)
        }
    }
    @objc func menuCloseWindow(_ sender: Any?) {
        if let mini = keyMiniWindow { mini.window.performClose(nil); return }
        keyController?.window.performClose(nil)
    }
    @objc func menuReopen(_ sender: Any?) { if let id = keyWindowID { store.reopenClosedPage(in: id) } }
    @objc func menuNextPage(_ sender: Any?) { if let id = keyWindowID { store.selectAdjacent(offset: 1, in: id) } }
    @objc func menuPreviousPage(_ sender: Any?) { if let id = keyWindowID { store.selectAdjacent(offset: -1, in: id) } }
    @objc func menuSelectNumbered(_ sender: NSMenuItem) { if let id = keyWindowID { store.selectByShortcut(sender.tag, in: id) } }
    @objc func menuReload(_ sender: Any?) {
        if let mini = keyMiniWindow { mini.browser?.reload(); return }
        withSelectedPage { pool.reload($0) }
    }
    @objc func menuBack(_ sender: Any?) {
        if let mini = keyMiniWindow { mini.browser?.goBack(); return }
        withSelectedPage { pool.goBack($0) }
    }
    @objc func menuForward(_ sender: Any?) {
        if let mini = keyMiniWindow { mini.browser?.goForward(); return }
        withSelectedPage { pool.goForward($0) }
    }
    @objc func menuZoomIn(_ sender: Any?) { withSelectedPage { pool.zoom($0, by: 0.5) } }
    @objc func menuZoomOut(_ sender: Any?) { withSelectedPage { pool.zoom($0, by: -0.5) } }
    @objc func menuZoomReset(_ sender: Any?) { withSelectedPage { pool.resetZoom($0) } }
    @objc func menuKeepSite(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID,
              let site = window.site(containing: page) else { return }
        store.setKept(site.id, !site.isKept)
    }
    @objc func menuPinSite(_ sender: Any?) { withSelectedSite { store.pin(site: $0) } }
    @objc func menuPutAway(_ sender: Any?) { withSelectedSite { store.shelve(site: $0) } }
    @objc func menuSplitWithNext(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID else { return }
        let order = BarOrder.pageOrder(pins: store.pins(in: id), sites: window.sites)
        guard let i = order.firstIndex(of: page), order.count > 1 else { return }
        store.split(page, with: order[(i + 1) % order.count], in: id)
    }
    @objc func menuEndSplit(_ sender: Any?) { if let id = keyWindowID { store.endSplit(in: id) } }
    @objc func menuUseDock(_ sender: Any?) { prefs.update { $0.tabLayout = .dock } }
    @objc func menuUseSidebar(_ sender: Any?) { prefs.update { $0.tabLayout = .sidebar } }
    @objc func menuToggleSidebar(_ sender: Any?) {
        if prefs.value.tabLayout == .dock { prefs.update { $0.tabLayout = .sidebar; $0.sidebarCollapsed = false } }
        else { prefs.update { $0.sidebarCollapsed.toggle() } }
    }
    @objc func menuManageExtensions(_ sender: Any?) { openInNewPage(URL(string: "chrome://extensions")!) }
    @objc func menuGetExtensions(_ sender: Any?) { openInNewPage(URL(string: "https://chromewebstore.google.com/category/extensions")!) }
    @objc func menuDownloads(_ sender: Any?) { keyController?.toggleDownloads() }
    @objc func menuHistory(_ sender: Any?) { keyController?.toggleHistory() }
    @objc func menuDevTools(_ sender: Any?) { withSelectedPage { pool.existing($0)?.executeChromeCommand("IDC_DEV_TOOLS") } }
}

extension ChromiumApp: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuUseDock(_:)): item.state = prefs.value.tabLayout == .dock ? .on : .off
        case #selector(menuUseSidebar(_:)): item.state = prefs.value.tabLayout == .sidebar ? .on : .off
        case #selector(menuToggleAI(_:)): item.state = ai.isEnabled ? .on : .off
        case #selector(menuPromoteMini(_:)): return keyMiniWindow != nil || keyController?.isPeeking == true
        case #selector(menuToggleSync(_:)): item.state = sync != nil ? .on : .off
        case #selector(menuBookmarkPage(_:)):
            return keyMiniWindow == nil && keyWindowID.flatMap { store.window($0)?.selectedPageID } != nil
        default: break
        }
        return true
    }
}
