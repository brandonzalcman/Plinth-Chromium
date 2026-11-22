import AppKit
import PlinthModel
import PlinthStore
import PlinthSync

// iCloud sync, as in the Mac app: off by default, the "iCloud Sync" menu item and Settings turn it on,
// and it shares what the Mac shares (pins and pin folders, the shelf, history, each device's open pages
// and the points ledger) through the same CloudKit container. See SyncGate.swift for when it can run.

/// The store's side of a sync, shared by the app and its tests.
@MainActor
enum SyncWiring {
    @discardableResult
    static func syncNow(_ coordinator: SyncCoordinator, store: BrowserStore) async -> Result<[DeviceOpenPages], Error> {
        await coordinator.syncNow(local: { store.syncPayload() }, openPages: { store.openPagesSummary() },
                                  apply: { store.applySynced($0) })
    }

    static func schedule(_ coordinator: SyncCoordinator, store: BrowserStore) {
        coordinator.scheduleSync(local: { store.syncPayload() }, openPages: { store.openPagesSummary() },
                                 apply: { store.applySynced($0) })
    }
}

extension ChromiumApp {
    /// A scratch profile (PLINTH_STORAGE) syncs only with an in-memory server, and only with PLINTH_SYNC=memory.
    /// It never reads or writes the real switch, and never reaches iCloud, even in a signed build.
    private var syncsInMemory: Bool { isScratchProfile && ProcessInfo.processInfo.environment["PLINTH_SYNC"] == "memory" }

    /// The user's switch (off by default).
    var syncSwitchOn: Bool {
        get { isScratchProfile ? scratchSyncSwitch : SyncSettings().isEnabled }
        set { if isScratchProfile { scratchSyncSwitch = newValue } else { SyncSettings().isEnabled = newValue } }
    }

    var syncState: SyncGate.State {
        SyncGate.state(enabled: syncSwitchOn, containers: isScratchProfile ? nil : SyncGate.entitledContainers(),
                       inMemory: syncsInMemory && syncSwitchOn)
    }

    /// True when turning the switch on would actually sync.
    var canSync: Bool { syncsInMemory || (!isScratchProfile && SyncGate.canSync(containers: SyncGate.entitledContainers())) }

    private func makeSyncEngine() -> SyncEngine? {
        switch syncState {
        case .ready(let container):
            let settings = SyncSettings()
            return SyncEngine(transport: CloudKitTransport(containerIdentifier: container), deviceID: settings.deviceID,
                              deviceName: SyncSettings.deviceName, stateURL: storageDirectory.appendingPathComponent("sync-state.json"))
        case .inMemory:
            let transport = memorySyncTransport ?? InMemoryTransport()
            memorySyncTransport = transport
            return SyncEngine(transport: transport, deviceID: "scratch-profile", deviceName: "Scratch profile", stateURL: nil)
        case .off, .needsSignedBuild, .wrongContainer:
            return nil
        }
    }

    /// Starts syncing if the switch is on and this build can reach iCloud. Called at launch and when the
    /// switch is turned on. Constructs nothing from CloudKit otherwise.
    func startSyncIfConfigured() {
        guard sync == nil, let engine = makeSyncEngine() else { return }
        let coordinator = SyncCoordinator(engine: engine)
        coordinator.onSyncFinished = { [weak self] result in
            if case .success(let devices) = result { self?.otherDevices = devices }
            self?.ingestLoyaltyFromSync()
        }
        sync = coordinator
        connectLoyalty(to: coordinator)
        Task { @MainActor [weak self] in
            guard let self, let sync = self.sync else { return }
            if case .success(let devices) = await SyncWiring.syncNow(sync, store: self.store) { self.otherDevices = devices }
            self.ingestLoyaltyFromSync()
            self.observeForSync()
        }
    }

    func stopSync() {
        sync?.cancelScheduled()
        sync = nil
        otherDevices = []
    }

    /// Turns the switch on or off. Turning it on in a build that can't sync explains why instead.
    func setSyncEnabled(_ on: Bool) {
        if !on {
            syncSwitchOn = false
            stopSync()
            return
        }
        guard canSync else {
            let alert = NSAlert()
            alert.messageText = "iCloud needs a signed build"
            alert.informativeText = SyncGate.explanation(SyncGate.state(enabled: true, containers: SyncGate.entitledContainers()))
                + " See docs/icloud-sync.md for the steps."
            alert.runModal()
            return
        }
        syncSwitchOn = true
        startSyncIfConfigured()
    }

    @objc func menuToggleSync(_ sender: Any?) { setSyncEnabled(sync == nil) }

    @objc func menuOpenRemotePage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openInNewPage(url)
    }

    /// Syncs again after local changes, a few seconds after the last one.
    private func observeForSync() {
        guard sync != nil else { return }
        withObservationTracking {
            _ = store.pins
            _ = store.shelf
            _ = store.history.count
            _ = store.windows.map { $0.sites.count }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let sync = self.sync else { return }
                SyncWiring.schedule(sync, store: self.store)
                self.observeForSync()
            }
        }
    }

    // MARK: Points

    func connectLoyalty(to coordinator: SyncCoordinator) {
        guard let loyalty, !isScratchProfile || syncsInMemory else { return }
        coordinator.engine.ownLoyaltyLedger = loyalty.engine.ownLedgerData
    }

    func ingestLoyaltyFromSync() {
        guard let loyalty, let engine = sync?.engine, !isScratchProfile || syncsInMemory else { return }
        loyalty.engine.ingest(engine.loyaltyLedgers())
    }

    /// The ledger changed here: hand it to the next sync.
    func pushLoyaltyToSync() {
        guard let loyalty, let coordinator = sync, !isScratchProfile || syncsInMemory else { return }
        coordinator.engine.ownLoyaltyLedger = loyalty.engine.ownLedgerData
        SyncWiring.schedule(coordinator, store: store)
    }
}

/// "Pages on Other Devices": filled from the last sync when the submenu opens.
@MainActor
final class RemotePagesMenu: NSObject, NSMenuDelegate {
    static let title = "Pages on Other Devices"
    unowned let app: ChromiumApp

    init(app: ChromiumApp) { self.app = app }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for device in app.otherDevices where !device.pages.isEmpty {
            menu.addItem(withTitle: device.deviceName, action: nil, keyEquivalent: "").isEnabled = false
            for page in device.pages {
                let item = NSMenuItem(title: page.name, action: #selector(ChromiumApp.menuOpenRemotePage(_:)), keyEquivalent: "")
                item.target = app
                item.representedObject = page.url
                item.indentationLevel = 1
                item.image = app.pool.favicons.image(for: page.key)
                menu.addItem(item)
            }
        }
        if menu.items.isEmpty {
            let text = app.sync == nil ? "iCloud Sync Is Off" : "No Pages Open on Other Devices"
            menu.addItem(withTitle: text, action: nil, keyEquivalent: "").isEnabled = false
        }
    }
}
