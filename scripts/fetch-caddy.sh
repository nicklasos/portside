#!/usr/bin/env bash
# Downloads the pinned Caddy release for both Mac architectures, verifies the
# SHA-512 checksums, and writes an ad-hoc signed universal binary to Portside/Resources/caddy.
set -euo pipefail
cd "$(dirname "$0")/.."

V="$(tr -d '[:space:]' < scripts/CADDY_VERSION)"
OUT="Portside/Resources/caddy"
LICENSE_OUT="Portside/Resources/Licenses/caddy-LICENSE.txt"
BASE="https://github.com/caddyserver/caddy/releases/download/v${V}"

if [ -x "$OUT" ] && [ -f "$LICENSE_OUT" ] && "$OUT" version 2>/dev/null | grep -q "^v${V}[ ]" \
  && codesign --verify "$OUT" 2>/dev/null; then
  echo "caddy v${V} already present at $OUT"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/checksums.txt" "$BASE/caddy_${V}_checksums.txt"
for ARCH in arm64 amd64; do
  ASSET="caddy_${V}_mac_${ARCH}.tar.gz"
  echo "downloading $ASSET"
  curl -fsSL -o "$TMP/$ASSET" "$BASE/$ASSET"
  EXPECTED="$(awk -v f="$ASSET" '$2 == f { print $1 }' "$TMP/checksums.txt")"
  if [ -z "$EXPECTED" ]; then
    echo "error: no checksum for $ASSET" >&2
    exit 1
  fi
  ACTUAL="$(shasum -a 512 "$TMP/$ASSET" | awk '{ print $1 }')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "error: SHA-512 mismatch for $ASSET" >&2
    exit 1
  fi
  mkdir -p "$TMP/$ARCH"
  tar -xzf "$TMP/$ASSET" -C "$TMP/$ARCH"
done

mkdir -p "$(dirname "$OUT")" "$(dirname "$LICENSE_OUT")"
lipo -create -output "$TMP/caddy" "$TMP/arm64/caddy" "$TMP/amd64/caddy"
chmod +x "$TMP/caddy"
# Only the arm64 slice arrives linker-signed; the app's codesign rejects an unsigned nested binary.
codesign --force --sign - --identifier com.caddyserver.caddy "$TMP/caddy"
mv -f "$TMP/caddy" "$OUT"
cp -f "$TMP/arm64/LICENSE" "$LICENSE_OUT"

echo "installed $("$OUT" version) ($(lipo -archs "$OUT")) at $OUT"
