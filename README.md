# mobilerun-swift

## Status: pre-release core

Pure Swift protocol and reconnect libraries for embedding device streaming. Requires Swift 6.0
or newer; supports iOS 15 and macOS 13 or newer. This slice has no networking, WebRTC, or UI.

- `MobilerunProtocol`: control packet encoders, protocol constants, typed signalling messages,
  phase-aware server parsing, timings, and negotiated channel specifications.
- `MobilerunStreamCore`: reconnect policy and controller with an injected serial scheduler.

All value messages are Sendable. Use the mutable reconnect controller and its scheduled callbacks
on one serial context. The host supplies timers, remounts the connection when requested, and calls
`attemptMounted()` after every restart. `dispose()` permanently stops the controller.

## Tests

```sh
swift build
swift test
```

Tests read the vendored `v0.1.0` conformance fixtures from `conformance/fixtures`. They compare
control packets byte-for-byte, signalling objects field-for-field, and reconnect scenarios using
a fake clock with deterministic ordering for equal deadlines. No network access is needed.

To refresh from a local conformance repository clone and regenerate constants:

```sh
tool/sync-conformance.sh v0.1.0 /path/to/conformance-clone
python3 tool/generate-constants.py
```

Licensed under Apache-2.0; see [LICENSE](LICENSE).
