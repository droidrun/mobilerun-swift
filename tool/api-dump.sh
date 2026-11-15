#!/bin/bash
# Dump public declarations for both supported platforms with the selected Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--check) ;;
  *) echo 'Usage: tool/api-dump.sh [--check]' >&2; exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for platform in macOS iOS; do
  # SwiftPM shares this output directory between destination triples.
  rm -rf .build/out/symbolgraph
  if [[ "$platform" == macOS ]]; then
    swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members
  else
    swift package --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
      --triple arm64-apple-ios15.0-simulator dump-symbol-graph \
      --minimum-access-level public --skip-synthesized-members
  fi
  python3 tool/normalize-api.py "$platform" .build/out/symbolgraph >> "$work/api.txt"
done
mkdir -p api
if [[ "${1:-}" == --check ]]; then
  cp "$work/api.txt" .build/api-current.txt
  diff -u api/MobilerunStream.api.txt .build/api-current.txt
else
  cp "$work/api.txt" api/MobilerunStream.api.txt
fi
