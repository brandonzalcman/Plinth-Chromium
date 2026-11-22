# iCloud sync

Plinth Chromium syncs what the Mac app syncs, through the same CloudKit container
(`iCloud.dev.getplinth.Plinth`) and the same code (`PlinthSync` from the Plinth package): pins and pin
folders, the shelf, history (the newest 20,000 visits), each device's open pages (shown read-only in
**File ▸ Pages on Other Devices**) and the points ledger. Bookmarks, passwords, settings and windows don't
sync, as in the Mac app. The records and merge rules are in the Plinth repository's `docs/icloud-sync.md`.

Sync is **off by default** and is turned on with **Plinth ▸ iCloud Sync** or **Settings ▸ iCloud**.

## Why the usual build can't sync

CloudKit only works in an app signed by a team, carrying the iCloud entitlement for the container, with a
provisioning profile that allows it. `Scripts/bundle.sh` signs ad hoc by default, so that build has no
entitlement. Plinth checks the entitlement before it touches CloudKit (`SyncGate`): in the ad-hoc build the
switch stays off and Settings says "iCloud needs a signed build". Nothing crashes.

A scratch profile (`PLINTH_STORAGE`) never reaches iCloud, even in a signed build. With `PLINTH_SYNC=memory`
it syncs with an in-memory server instead, which is how the wiring is checked (`PLINTH_STEPS="… syncpeer;
syncnow; sync"`).

## Turning it on

You need an Apple Developer Program membership. Once, on developer.apple.com ▸ Certificates, Identifiers &
Profiles:

1. **The container.** It already exists for the Mac app (`iCloud.dev.getplinth.Plinth`). If not:
   Identifiers ▸ **+** ▸ iCloud Containers, identifier `iCloud.dev.getplinth.Plinth`.
2. **The App ID.** Identifiers ▸ **+** ▸ App IDs ▸ App, platform macOS, Bundle ID (explicit)
   `dev.getplinth.chromium`. Tick **iCloud**, choose **Include CloudKit support**, then **Configure** and tick
   `iCloud.dev.getplinth.Plinth`. Save.
3. **A certificate** in your login keychain: an **Apple Development** certificate for builds on your own
   Macs, or **Developer ID Application** for builds you give to others. Xcode ▸ Settings ▸ Accounts ▸ Manage
   Certificates makes either.
4. **A provisioning profile** for App ID `dev.getplinth.chromium`:
   - for your own Macs, Profiles ▸ **+** ▸ Development ▸ **macOS App Development**, pick the certificate
     and the Macs you'll run it on;
   - for distribution, Profiles ▸ **+** ▸ Distribution ▸ **Developer ID**.
   Download the `.provisionprofile`.

Then build and sign:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
security find-identity -v -p codesigning          # the exact identity name
Scripts/bundle.sh release --sign "Apple Development: Your Name (ABCDE12345)" \
                          --profile ~/Downloads/Plinth_Chromium_Development.provisionprofile
open "build/Plinth Chromium.app"
```

The script checks that the profile is for `<TEAM>.dev.getplinth.chromium` and includes the container,
fills the team into `Signing/PlinthChromium.entitlements`, embeds the profile as
`Contents/embedded.provisionprofile` and signs the framework, the five helpers and the app. A Developer ID
profile also gets `com.apple.developer.icloud-container-environment = Production`; a development one talks
to CloudKit's Development environment. For a build you notarize, add `--hardened` (the hardened runtime,
with `Signing/Helper.entitlements` for Chromium's JIT in its helpers), then notarize and staple as usual.

Check it with `codesign -d --entitlements - "build/Plinth Chromium.app"`: the container should be listed.
Sign in to iCloud on the Mac, open Plinth, and turn on **Plinth ▸ iCloud Sync**.

**Production schema.** A Developer ID build talks to CloudKit's Production environment, which has record
types only once the Mac app's schema has been deployed there (see the Plinth repository's
`docs/icloud-sync.md`, "Deploying the CloudKit schema"). Both apps share it.

## The Xcode route

Instead of the script, an Xcode app target can wrap the `PlinthChromium` executable: add the package,
make a macOS App target with bundle ID `dev.getplinth.chromium`, add a library product for `PlinthChromiumApp`, link it and call
`ChromiumApp.main()` from its `main.swift`, copy the CEF framework and the five helper apps into
`Contents/Frameworks` in a build phase (as `Scripts/bundle.sh` does), and turn on **Signing & Capabilities ▸
iCloud ▸ CloudKit** with the container `iCloud.dev.getplinth.Plinth`. Xcode then makes the profile and
signs. The script route is simpler while the app has no Xcode project.
