import SwiftUI
import PlinthSync

/// iCloud sync: the switch, whether this build can sync at all, and what is shared.
struct SyncSettingsView: View {
    let app: ChromiumApp
    @Environment(\.settingsTheme) private var t
    /// Redrawn after the switch changes (the coordinator isn't observed).
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let on = app.sync != nil
        // Why the switch can't turn on, when it can't.
        let blocked = SyncGate.state(enabled: true, containers: app.isScratchProfile ? nil : SyncGate.entitledContainers())
        SettingsPage(title: "iCloud", subtitle: "Share pins, the shelf, history and open pages with Plinth on your other Macs and your iPhone, through your iCloud account.") {
            SettingsCard(heading: "Sync") {
                SettingsToggleRow(title: "iCloud Sync", caption: on ? SyncGate.explanation(app.syncState) : (app.canSync ? SyncGate.explanation(.off) : "Off."),
                                  isOn: Binding(get: { app.sync != nil }, set: { app.setSyncEnabled($0); revision += 1 }))
                if !app.canSync {
                    SettingsDivider()
                    SettingsNote(text: SyncGate.explanation(blocked) + " See docs/icloud-sync.md in the Plinth Chromium repository.", tone: .warning)
                }
                if on, let error = app.sync?.lastError {
                    SettingsDivider()
                    SettingsNote(text: "The last sync didn't finish: \(Self.describe(error))", tone: .error)
                }
            }
            SettingsCard(heading: "What syncs") {
                SettingsNote(text: "Pins and pin folders, the shelf, history (the newest 20,000 visits), the pages open on each device (read-only elsewhere, in File ▸ Pages on Other Devices) and points. Bookmarks, passwords, settings and windows stay on this Mac, as in the Mac app.")
            }
            if on, !app.otherDevices.isEmpty {
                SettingsCard(heading: "Other devices") {
                    ForEach(Array(app.otherDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(title: device.deviceName, caption: "\(device.pages.count) page\(device.pages.count == 1 ? "" : "s") open, updated \(device.updatedAt.formatted(.relative(presentation: .named))).") {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? SyncError {
        case .notSignedIn: "this Mac isn't signed in to iCloud."
        case .notConfigured: "this build has no iCloud entitlement."
        case .transport(let message): message
        default: "\(error.localizedDescription)"
        }
    }
}
