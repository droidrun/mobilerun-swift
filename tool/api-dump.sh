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
  rm -rf .build/*/symbolgraph
  if [[ "$platform" == macOS ]]; then
    swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members 2>&1 | tee "$work/graph.log"
  else
    swift package --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
      --triple arm64-apple-ios15.0-simulator dump-symbol-graph \
      --minimum-access-level public --skip-synthesized-members 2>&1 | tee "$work/graph.log"
  fi
  graph_dir=$(sed -n 's/^Files written to //p' "$work/graph.log" | tail -n 1)
  if [[ -z "$graph_dir" || ! -d "$graph_dir" ]]; then
    echo "Missing symbol-graph output directory" >&2
    exit 1
  fi
  python3 tool/normalize-api.py "$platform" "$graph_dir" >> "$work/api.txt"
done
mkdir -p api
if [[ "${1:-}" == --check ]]; then
  cp "$work/api.txt" .build/api-current.txt
  diff -u api/MobilerunStream.api.txt .build/api-current.txt
else
  cp "$work/api.txt" api/MobilerunStream.api.txt
fi
