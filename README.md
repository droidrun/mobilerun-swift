# mobilerun-swift

Pre-release Swift libraries for live Mobilerun device streams. Requires Swift 6.0 or newer.
The connection library supports iOS 15+; the pure protocol and session core also support macOS 13+.

- `MobilerunStream`: observable session, WebSocket signalling and native WebRTC on iOS.
- `MobilerunProtocol`: binary control encoders, typed signalling and protocol constants.
- `MobilerunStreamCore`: package implementation of session orchestration, transport boundaries and reconnect timers.

## Connect

Add the `MobilerunStream` library product to your app. It pins LiveKitWebRTC to exactly
`150.7871.05` (SwiftPM normalizes the version to `150.7871.5`).

```swift
import MobilerunStream
import MobilerunProtocol

// Create and use the session on the main actor. The provider may fetch from your API.
let session = DeviceStreamSession(credentials: {
    guard let response = try await loadStreamCredentials() else { return nil }
    return StreamCredentials(url: response.url, token: response.token)
})
session.start()
// Observe session.status and session.videoSize.
// Rendering is reserved for the package's upcoming view component.

let sent = session.sendControl(ControlMessages.touch(
    action: MotionEvent.actionDown, pointerID: 0,
    videoWidth: 1080, videoHeight: 1920, x: 200, y: 300
))
session.openURL("https://example.com")
let image = try await session.screenshot(timeout: 30)
// When finished:
session.setMuted(true)
session.close()
```

The session is an `@MainActor ObservableObject`. Native video tracks are internal to the package.
It publishes `status` (`connecting`, `connected`,
`reconnecting(attempt:)`, `unavailable`, or `closed`) and `videoSize` (raw frame width,
height and clockwise rotation). `start()` is idempotent; `close()` is permanent. Call `retry()` when
unavailable to start a fresh retry budget and fetch fresh credentials. The credentials provider runs
at start, on recovery, and when a token is rejected. Nil means the device is not ready; retries remain bounded by the normal
backoff budget. Credentials are never logged by the SDK.

A closed signalling socket or failed/closed peer rebuilds both transports through the reconnect
controller, with up to six retries and exponential backoff. Every connection requests fresh RTC
configuration. Live configuration updates replace ICE servers and send an ICE-restart offer;
non-terminal state dips are suppressed for up to 15 seconds, with a deadline recheck. The host
owns app lifecycle decisions; the session installs no app lifecycle observers.

`sendControl` and `sendHover` return false when their respective channels are not open. Hover
uses channel 2 only; it never falls back to control channel 1. `openURL` sends now if control is
open, otherwise queues the latest URL for the next channel opening. `screenshot` returns decoded
image bytes, or throws `StreamError` on disconnect, timeout, failure or no open socket; cancelling
the caller cancels its pending request. Timeouts use the protocol default and are capped at 24 hours.
Raw control bytes are not input/view coordinate mapping.

Audio is muted by default. Use `setMuted(_:)` to update received audio; unmuted sessions enable the
shared native audio gate. Muted sessions use manual audio and do not activate the WebRTC audio
session, allowing the embedding app to keep playing its own audio. Automatic codec
preferences are VP9, H.265, H.264, then the rest; the server selects from the offer. If the receiver
has no H.265 decoder, only H.264 is offered. `StreamConfig(videoCodec: .h264Only)` explicitly forces
that fallback while preserving retransmission and redundancy codecs. The pinned framework exposes
no receiver playout-delay/jitter-buffer target setter,
so the SDK cannot apply the browser's zero-playout-delay hint.

All sessions share one peer connection factory, initialized lazily on the main actor and retained
for the process lifetime. `close()` releases the session's WebSocket, peer, data channels, timers,
requests and media references. Dropping the session also tears down its transports; explicit close
is recommended for deterministic release.

## Validation

```sh
swift test
xcodebuild -scheme MobilerunStream -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
```

macOS tests use fake transports and a virtual clock, without loading WebRTC. They replay the
vendored conformance sequence, initial negotiation and refresh, candidate buffering, timer
spacing, full reconnects, credential rejection, channel guards, and screenshot completion paths.
Fixtures are pinned in [`conformance/VERSION`](conformance/VERSION).

[`Examples/Connection`](Examples/Connection) contains a minimal simulator validation app and
runner. It uses the actual library, renders its video track, sends S1 raw touch packets, and
exercises refresh plus forced socket loss through Debug-only test access. Credentials are injected at runtime
into the installed app's Documents directory; they are never app resources. Run its Python script
under your machine's exclusive simulator lock, with `--credentials`, `--evidence`, `--shots`,
`--tap-x` and `--tap-y`. It creates one disposable iOS 27.2 iPhone simulator and removes it and
DerivedData on exit. Tap coordinates are raw video pixels; choose a harmless screen navigation.
Refresh verification requires a changed local ICE username fragment and at least 16 seconds of
growing decoded-frame counts without reconnecting. A generated host-app tone verifies that muted
streaming preserves playback and never activates native WebRTC audio; unsupported playback is
reported explicitly. `--h264-only` also checks the offer includes H.264 and auxiliary codecs.
`--tap-coordinates-file` can supply video pixel coordinates after the first screenshot, and
`--skip-tap` omits the input check for an additional codec run. Screenshots require visual comparison
to establish that the tap changed the remote screen. The example uses `@testable` in Debug; Release
contains no native-track or diagnostic access. Import `MobilerunProtocol` explicitly for S1 encoders.

To refresh protocol fixtures:

```sh
tool/sync-conformance.sh "$(cat conformance/VERSION)" /path/to/conformance-clone
python3 tool/generate-constants.py
```

Licensed under Apache-2.0; see [LICENSE](LICENSE).
