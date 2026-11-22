import Foundation
import Security

/// Whether this copy of Plinth can use iCloud, and what to say when it can't.
///
/// CloudKit needs an app signed with a team, carrying the iCloud entitlement for Plinth's container and a
/// provisioning profile that allows it. `Scripts/bundle.sh` signs ad hoc by default, so that build has no
/// entitlement: sync stays off and Plinth says it needs a signed build, rather than letting CloudKit crash.
enum SyncGate {
    /// The container the Mac app syncs through. The Chromium build uses the same one, so both share
    /// pins, the shelf, history and open pages.
    static let container = "iCloud.dev.getplinth.Plinth"
    static let containerEntitlement = "com.apple.developer.icloud-container-identifiers"

    enum State: Equatable {
        /// The switch is off.
        case off
        /// On, but the build has no iCloud entitlement (the ad-hoc build).
        case needsSignedBuild
        /// On, but signed for other containers, not Plinth's.
        case wrongContainer(found: [String])
        /// On, and CloudKit can be used.
        case ready(container: String)
        /// A scratch profile syncing with an in-memory server (`PLINTH_SYNC=memory`).
        case inMemory
    }

    /// The pure rule. `containers` is what the running app's entitlement lists (nil: no entitlement).
    static func state(enabled: Bool, containers: [String]?, inMemory: Bool = false) -> State {
        if inMemory { return .inMemory }
        guard enabled else { return .off }
        guard let containers, !containers.isEmpty else { return .needsSignedBuild }
        guard containers.contains(container) else { return .wrongContainer(found: containers) }
        return .ready(container: container)
    }

    /// True when the switch can be turned on and actually sync.
    static func canSync(containers: [String]?) -> Bool { containers?.contains(container) == true }

    /// The iCloud containers in the running app's entitlements, or nil when it has none.
    static func entitledContainers() -> [String]? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, containerEntitlement as CFString, nil) else { return nil }
        return (value as? [String])?.filter { !$0.isEmpty }
    }

    /// What Settings and the menu say about a state.
    static func explanation(_ state: State) -> String {
        switch state {
        case .off:
            "Off. Turn it on to share pins, the shelf, history and open pages with your other devices."
        case .needsSignedBuild:
            "iCloud needs a signed build. This copy of Plinth is signed ad hoc, so it has no iCloud entitlement; build it with Scripts/bundle.sh --sign and a provisioning profile to turn sync on."
        case .wrongContainer(let found):
            "This build is signed for \(found.joined(separator: ", ")), not \(container), so it can't reach Plinth's iCloud data."
        case .ready:
            "On. Pins, the shelf, history and open pages sync through your iCloud account."
        case .inMemory:
            "On, with a test server in memory (scratch profile). Nothing reaches iCloud."
        }
    }
}
