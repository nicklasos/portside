#!/usr/bin/env bash
# Writes dist/appcast.xml for dist/Portside-<version>.zip, signed with the EdDSA key in
# $SPARKLE_PRIVATE_KEY, with release notes from the matching CHANGELOG.md section.
# Usage: SPARKLE_PRIVATE_KEY=... scripts/generate-appcast.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' project.yml | head -n 1)}"
DIST="$ROOT/dist"
ZIP="$DIST/Portside-$VERSION.zip"
NOTES="$DIST/Portside-$VERSION.md"
STAGE="$ROOT/build/appcast"
DOWNLOAD_PREFIX="https://github.com/nicklasos/portside/releases/download/v$VERSION/"

[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || { echo "SPARKLE_PRIVATE_KEY is not set" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "$ZIP not found; run scripts/build-release.sh $VERSION first" >&2; exit 1; }

find_tool() {
  find "$ROOT/build" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -n 1
}
GENERATE_APPCAST="$(find_tool)"
if [ -z "$GENERATE_APPCAST" ]; then
  RESOLVED="$ROOT/Portside.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  SPARKLE_VERSION="$(awk '/"identity" *: *"sparkle"/ { found = 1 } found && /"version"/ { gsub(/[",]/, ""); print $3; exit }' "$RESOLVED")"
  TOOLS="$ROOT/build/sparkle-$SPARKLE_VERSION"
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
  GENERATE_APPCAST="$TOOLS/bin/generate_appcast"
fi

awk -v version="$VERSION" '
  /^## / { if (inside) exit; if (index($0, "[" version "]") || $2 == version || $2 == "v" version) { inside = 1; next } }
  inside { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES"
[ -s "$NOTES" ] || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"
rm -f "$DIST/appcast.xml"
cp "$ZIP" "$NOTES" "$STAGE/"

printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --maximum-deltas 0 \
  -o "$DIST/appcast.xml" \
  "$STAGE"

# generate_appcast exits 0 but leaves the enclosure unsigned when the app's SUPublicEDKey
# is missing or does not match the private key; Sparkle clients would reject that update.
if ! grep -q 'sparkle:edSignature=' "$DIST/appcast.xml"; then
  echo "appcast.xml is unsigned: SUPublicEDKey in Portside/App/Info.plist must match SPARKLE_PRIVATE_KEY" >&2
  exit 1
fi

echo "Wrote $DIST/appcast.xml and $NOTES"
