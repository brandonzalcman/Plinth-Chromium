#!/bin/zsh
# Builds Plinth Chromium and assembles a runnable, ad-hoc signed app bundle:
#   build/Plinth Chromium.app
#     Contents/MacOS/Plinth Chromium
#     Contents/Frameworks/Chromium Embedded Framework.framework
#     Contents/Frameworks/Plinth Chromium Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
# Usage: Scripts/bundle.sh [debug|release] [--sign "<identity>" [--profile <file.provisionprofile>] [--hardened]]
#   (default: debug, signed ad hoc)
#
# Ad hoc (the default) runs on this Mac but has no iCloud: Settings says "iCloud needs a signed build".
# --sign signs with a certificate from your keychain ("Apple Development: …" or "Developer ID Application: …").
# --profile embeds that provisioning profile and signs with Signing/PlinthChromium.entitlements, the iCloud
#   (CloudKit) entitlements for iCloud.dev.getplinth.Plinth, with the team taken from the profile. The
#   profile must be for the App ID dev.getplinth.chromium with iCloud on. See docs/icloud-sync.md.
# --hardened turns on the hardened runtime (needed for notarization), with Signing/Helper.entitlements
#   for Chromium's helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="debug"
IDENTITY="-"
PROFILE=""
HARDENED=0
while (( $# )); do
  case "$1" in
    debug|release) CONFIG="$1" ;;
    --sign) IDENTITY="${2:?--sign needs a signing identity}"; shift ;;
    --profile) PROFILE="${2:?--profile needs a .provisionprofile file}"; shift ;;
    --hardened) HARDENED=1 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done
if [[ -n "$PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "--profile needs --sign: a provisioning profile only works with a real signing identity." >&2
  exit 64
fi
NAME="Plinth Chromium"
BUNDLE_ID="dev.getplinth.chromium"
VERSION="0.1.0"
BUILD_NUMBER="1"

Scripts/fetch-cef.sh >/dev/null
swift build -c "$CONFIG" --product PlinthChromium
swift build -c "$CONFIG" --product PlinthChromiumHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/PlinthChromium" "$APP/Contents/MacOS/$NAME"
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
[[ -f Scripts/Plinth.icns ]] && cp Scripts/Plinth.icns "$APP/Contents/Resources/Plinth.icns"
ditto "Vendor/cef/Release/Chromium Embedded Framework.framework" \
      "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"

plist() {   # plist <path> <executable> <identifier> <is-helper>
  local agent="" types=""
  [[ "$4" == "1" ]] && agent="<key>LSUIElement</key><true/>"
  # The sidebar's drag payloads (sites, pages, pins). macOS drops drags of undeclared types.
  [[ "$4" == "0" ]] && types="<key>UTExportedTypeDeclarations</key><array>
    <dict><key>UTTypeIdentifier</key><string>dev.getplinth.chromium.site</string>
      <key>UTTypeDescription</key><string>Plinth page</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array></dict>
    <dict><key>UTTypeIdentifier</key><string>dev.getplinth.chromium.pin</string>
      <key>UTTypeDescription</key><string>Plinth pin</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array></dict>
  </array>"
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>Plinth</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>PCEFApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use the microphone.</string>
  <key>NSLocationUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Plinth uses Bluetooth to sign in with a passkey from your phone or another nearby device, and for websites you allow to use Bluetooth devices.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>Plinth uses Bluetooth to sign in with a passkey from your phone or another nearby device.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Websites you allow, and casting to devices, can reach your local network.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Websites you allow can record audio.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web site URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  $agent
  $types
</dict></plist>
PLIST
}

plist "$APP/Contents/Info.plist" "$NAME" "$BUNDLE_ID" 0
# The app is the only executable that may run the PCEFApplication class; helpers ignore it.
for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  helper="$NAME Helper$suffix"
  dir="$APP/Contents/Frameworks/$helper.app/Contents"
  mkdir -p "$dir/MacOS"
  cp "$BIN/PlinthChromiumHelper" "$dir/MacOS/$helper"
  id_suffix="${${suffix//[ ()]/}:l}"
  plist "$dir/Info.plist" "$helper" "$BUNDLE_ID.helper${id_suffix:+.$id_suffix}" 1
done

# Sign inside out: the framework, the helpers, then the app.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null 2>&1
  for helper in "$APP"/Contents/Frameworks/*Helper*.app(N); do codesign --force --sign - "$helper" >/dev/null 2>&1; done
  codesign --force --sign - "$APP" >/dev/null 2>&1
else
  runtime=()
  helper_entitlements=()
  if (( HARDENED )); then
    runtime=(--options runtime --timestamp)
    helper_entitlements=(--entitlements Signing/Helper.entitlements)
  fi
  app_entitlements=()
  if [[ -n "$PROFILE" ]]; then
    decoded="build/profile.plist"
    security cms -D -i "$PROFILE" > "$decoded"
    pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$decoded" 2>/dev/null; }
    TEAM_ID="$(pb TeamIdentifier:0)"
    APP_ID="$(pb Entitlements:com.apple.application-identifier || pb Entitlements:application-identifier)"
    if [[ "$APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
      echo "The profile is for $APP_ID, not $TEAM_ID.$BUNDLE_ID." >&2
      exit 65
    fi
    if ! pb Entitlements:com.apple.developer.icloud-container-identifiers | grep -q "iCloud.dev.getplinth.Plinth"; then
      echo "The profile doesn't include the iCloud container iCloud.dev.getplinth.Plinth." >&2
      exit 65
    fi
    entitlements="build/PlinthChromium.entitlements"
    sed "s/TEAM_ID/$TEAM_ID/g" Signing/PlinthChromium.entitlements > "$entitlements"
    # A Developer ID (distribution) profile talks to CloudKit's Production environment; a development one
    # (it allows a debugger) to Development.
    if [[ "$(pb Entitlements:get-task-allow || echo false)" != "true" ]]; then
      /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$entitlements"
    fi
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    rm -f "$decoded"
    app_entitlements=(--entitlements "$entitlements")
    echo "Signing with iCloud for team $TEAM_ID."
  else
    echo "Signing without a provisioning profile: this build has no iCloud." >&2
  fi
  codesign --force --sign "$IDENTITY" "${runtime[@]}" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  for helper in "$APP"/Contents/Frameworks/*Helper*.app(N); do
    codesign --force --sign "$IDENTITY" "${runtime[@]}" "${helper_entitlements[@]}" "$helper"
  done
  codesign --force --sign "$IDENTITY" "${runtime[@]}" "${app_entitlements[@]}" "$APP"
  codesign --verify --strict "$APP"
fi
# Register the build so macOS knows its drag types straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "$APP"
