#!/bin/bash
# Dump public declarations for the iOS product and macOS test destination with the selected Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--check) ;;
  *) echo 'Usage: tool/api-dump.sh [--check]' >&2; exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
modules=(MobilerunStreamCore MobilerunStream)
for platform in macOS iOS; do
  if [[ "$platform" == macOS ]]; then
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    triple="$(uname -m)-apple-macosx13.0"
  else
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    triple=arm64-apple-ios15.0-simulator
  fi
  swift build --build-system native --sdk "$sdk" --triple "$triple"
  bin=$(swift build --build-system native --sdk "$sdk" --triple "$triple" --show-bin-path)
  graphs="$work/$platform"
  mkdir -p "$graphs"
  extract_flags=(-sdk "$sdk" -I "$bin/Modules")
  if [[ "$platform" == iOS ]]; then
    extract_flags+=(-F .build/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework/ios-arm64_x86_64-simulator)
  fi
  # Extract only shipping modules. SwiftPM 6.2 dumps test modules too and omits
  # the binary framework search path for the simulator destination.
  for module in "${modules[@]}"; do
    xcrun swift-symbolgraph-extract -module-name "$module" -target "$triple" \
      "${extract_flags[@]}" \
      -minimum-access-level public -skip-synthesized-members \
      -omit-extension-block-symbols -output-dir "$graphs"
  done
  python3 tool/normalize-api.py "$platform" "$graphs" "${modules[@]}" >> "$work/api.txt"
done
if [[ "${1:-}" == --check ]]; then
  cp "$work/api.txt" .build/api-current.txt
  if ! diff -u api/MobilerunStream.api.txt .build/api-current.txt; then
    echo '::error::Public API baseline differs. Regenerate with Xcode 26.2: tool/api-dump.sh' >&2
    exit 1
  fi
else
  mkdir -p api
  cp "$work/api.txt" api/MobilerunStream.api.txt
fi
