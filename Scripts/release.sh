#!/bin/zsh
# Builds a release of Plinth Chromium: Developer ID signing with the hardened runtime → DMG →
# notarization → Sparkle appcast. The DMG and feed are published in the public releases repo
# (brandonzalcman/plinth-chromium-releases), which holds only releases and the feed.
#
#   Scripts/release.sh 0.1.0
#
# Output: build/release/Plinth-Chromium-<version>.dmg and build/release/appcast.xml
#
# Needs, once:
#   - a "Developer ID Application" certificate in your keychain
#   - a notary profile: xcrun notarytool store-credentials plinth-notary …  (NOTARY_PROFILE to use another)
#   - Sparkle's EdDSA private key in your login keychain (the Mac app's; generate_keys put it there)
# Optional:
#   BUILD_NUMBER    defaults to the number of commits, which always increases
#   RELEASE_NOTES   a Markdown or HTML file whose text goes in the appcast item (shown in the update window)
#   SKIP_NOTARIZE=1 a signed but not notarized dry run (no appcast signature check by Gatekeeper)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="${1:?usage: Scripts/release.sh <version, e.g. 0.1.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Bad version '$VERSION'" >&2; exit 64; }
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plinth-notary}"
RELEASES="https://github.com/brandonzalcman/plinth-chromium-releases/releases"
FEED_URL="$RELEASES/latest/download/appcast.xml"
OUT="build/release"
NAME="Plinth Chromium"
DMG_NAME="Plinth-Chromium-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"

step() { print -P "%F{blue}==>%f $1"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application certificate in your keychain"

# Sparkle's tools come with the package (swift build resolves it).
swift package resolve >/dev/null
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "Sparkle's tools are missing from $SPARKLE_BIN"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || fail "no Sparkle key in your login keychain"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "no notary profile '$NOTARY_PROFILE' (xcrun notarytool store-credentials $NOTARY_PROFILE …)"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Building and signing Plinth Chromium $VERSION ($BUILD_NUMBER)"
OUT_DIR="$OUT" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" SPARKLE_FEED_URL="$FEED_URL" \
    Scripts/bundle.sh release --sign "$IDENTITY" --hardened >/dev/null
APP="$OUT/$NAME.app"
codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"

step "Making the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
    step "Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary.log"
    grep -q "status: Accepted" "$OUT/notary.log" || fail "notarization wasn't accepted (see $OUT/notary.log)"
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q accepted || fail "Gatekeeper rejects the DMG"
fi

step "Writing the update feed"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"   # sparkle:edSignature="…" length="…"
NOTES=""
if [[ -n "${RELEASE_NOTES:-}" && -f "$RELEASE_NOTES" ]]; then
    # The update window shows HTML: paragraphs, bullet lists and **bold** are enough for the notes.
    HTML="$(python3 - "$RELEASE_NOTES" <<'PY'
import html, re, sys
out, items = [], []
def flush():
    if items: out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>"); items.clear()
for line in open(sys.argv[1]).read().splitlines():
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(line.strip()))
    if line.startswith("- "): items.append(text[2:])
    else:
        flush()
        if text: out.append(f"<p>{text}</p>")
flush()
print("".join(out))
PY
)"
    NOTES="<description><![CDATA[$HTML]]></description>"
fi
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Plinth Chromium</title>
    <item>
      <title>Plinth Chromium $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      $NOTES
      <enclosure url="$RELEASES/download/v$VERSION/$DMG_NAME" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

step "Done"
echo "$DMG"
echo "$OUT/appcast.xml"
