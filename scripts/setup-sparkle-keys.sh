#!/usr/bin/env bash
# One-time setup of the Sparkle update signing key.
# Creates (or reuses) the EdDSA key in the login keychain, stores the private key in the
# SPARKLE_PRIVATE_KEY GitHub secret, and writes the public key into Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

bin=$(find build -path '*SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)
if [ -z "$bin" ]; then
  echo "Sparkle tools not found. Build the app once (xcodebuild or Xcode), then rerun." >&2
  exit 1
fi

"$bin/generate_keys" >/dev/null
public_key=$("$bin/generate_keys" -p)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
"$bin/generate_keys" -x "$tmp"
gh secret set SPARKLE_PRIVATE_KEY < "$tmp"

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" Portside/App/Info.plist

echo "Stored SPARKLE_PRIVATE_KEY on GitHub and set SUPublicEDKey in Portside/App/Info.plist:"
echo "  $public_key"
