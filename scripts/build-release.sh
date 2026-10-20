#!/usr/bin/env bash
# Builds an ad-hoc signed Portside.app and packages it as dist/Portside-<version>.zip and .dmg.
# Usage: scripts/build-release.sh [version]   (defaults to MARKETING_VERSION in project.yml)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' project.yml | head -n 1)}"
[ -n "$VERSION" ] || { echo "Could not read MARKETING_VERSION from project.yml" >&2; exit 1; }

BUILD="$ROOT/build"
DIST="$ROOT/dist"
ARCHIVE="$BUILD/Portside.xcarchive"
APP="$DIST/Portside.app"
ZIP="$DIST/Portside-$VERSION.zip"
DMG="$DIST/Portside-$VERSION.dmg"

if [ ! -f Portside/Resources/caddy ]; then
  if [ -x scripts/fetch-caddy.sh ]; then
    scripts/fetch-caddy.sh
  else
    echo "warning: scripts/fetch-caddy.sh not found; building without the bundled caddy" >&2
  fi
fi

xcodegen generate

rm -rf "$ARCHIVE" "$APP" "$ZIP" "$DMG"
mkdir -p "$BUILD" "$DIST"

xcodebuild archive \
  -project Portside.xcodeproj \
  -scheme Portside \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/dd" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  -quiet

ditto "$ARCHIVE/Products/Applications/Portside.app" "$APP"

sign() { codesign --force --sign - --options runtime --timestamp=none "$@"; }

# Sign inside-out: nested code first, the bundle that contains it last. `--deep` is
# deprecated for signing and does not apply per-item options such as entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for item in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app"; do
    if [ -e "$item" ]; then
      sign --preserve-metadata=entitlements "$item"
    fi
  done
  sign "$SPARKLE"
fi
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) ! -name Sparkle.framework -print0 2>/dev/null \
  | while IFS= read -r -d '' lib; do sign "$lib"; done
if [ -f "$APP/Contents/MacOS/caddy" ]; then
  sign "$APP/Contents/MacOS/caddy"
else
  echo "warning: $APP has no Contents/MacOS/caddy" >&2
fi
sign --entitlements Portside/Portside.entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

DMG_STAGE="$BUILD/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Portside.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Portside $VERSION" -srcfolder "$DMG_STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "Built Portside $VERSION:"
ls -la "$ZIP" "$DMG"
