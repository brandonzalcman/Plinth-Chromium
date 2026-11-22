#!/bin/zsh
# Builds Plinth Chromium and assembles a runnable, ad-hoc signed app bundle:
#   build/Plinth Chromium.app
#     Contents/MacOS/Plinth Chromium
#     Contents/Frameworks/Chromium Embedded Framework.framework
#     Contents/Frameworks/Plinth Chromium Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
# Usage: Scripts/bundle.sh [debug|release]   (default: debug)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-debug}"
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

# Sign inside out (ad hoc). Release signing and notarization: see docs/releasing.md.
codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null 2>&1
for helper in "$APP"/Contents/Frameworks/*Helper*.app(N); do codesign --force --sign - "$helper" >/dev/null 2>&1; done
codesign --force --sign - "$APP" >/dev/null 2>&1
# Register the build so macOS knows its drag types straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "$APP"
