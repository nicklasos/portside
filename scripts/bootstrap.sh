#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi

./scripts/fetch-caddy.sh
xcodegen generate
