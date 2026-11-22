#!/bin/zsh
# Downloads the CEF binary distribution into Vendor/cef (not checked in).
# Usage: Scripts/fetch-cef.sh            (the version pinned below)
set -euo pipefail
cd "$(dirname "$0")/.."

CEF_VERSION="158.0.3+g8c29be2+chromium-158.0.8127.18"
PLATFORM="macosarm64"
DIST="minimal"
NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_${DIST}"
URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME").tar.bz2"
DEST="Vendor/cef"

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$CEF_VERSION" ]]; then
  echo "CEF $CEF_VERSION already in $DEST"; exit 0
fi

mkdir -p Vendor/downloads
ARCHIVE="Vendor/downloads/$NAME.tar.bz2"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading $NAME"
  curl -fL -s -o "$ARCHIVE.part" "$URL"
  curl -fsL -o "$ARCHIVE.sha1" "$URL.sha1"
  echo "$(cat "$ARCHIVE.sha1")  $ARCHIVE.part" | shasum -a 1 -c - >/dev/null
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

rm -rf "$DEST" "Vendor/$NAME"
tar -xjf "$ARCHIVE" -C Vendor
mv "Vendor/$NAME" "$DEST"
# SwiftPM's CEFWrapper target needs a public headers folder of its own (CEF's include/ is C++).
mkdir -p "$DEST/plinth-public"
echo "// CEFWrapper has no Swift-visible API; PlinthCEF includes CEF headers directly." > "$DEST/plinth-public/CEFWrapper.h"
echo "$CEF_VERSION" > "$DEST/.version"
echo "CEF $CEF_VERSION in $DEST"
