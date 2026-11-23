import AppKit
import PlinthChromiumApp
import Sparkle

// Auto-updates start only when the build carries a Sparkle public key (SUPublicEDKey), which
// Scripts/release.sh puts in for signed releases. Local builds have none and never check.
let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
let updater: SPUStandardUpdaterController? = publicKey.isEmpty ? nil
    : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

MainActor.assumeIsolated {
    if let updater { ChromiumApp.checkForUpdates = { updater.checkForUpdates(nil) } }
    ChromiumApp.main()
}
