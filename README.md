# mobilerun-swift

Pre-release Swift libraries for live Mobilerun device streams. Requires Swift 6.0 or newer.
The connection library supports iOS 15+; the pure protocol and session core also support macOS 13+.

- `MobilerunStream`: observable session, SwiftUI/UIKit video and input, and native WebRTC on iOS.
- `MobilerunProtocol`: binary control encoders, typed signalling and protocol constants.
- `MobilerunStreamCore`: package implementation of session orchestration, transport boundaries and
  reconnect timers.

## Connect

Add the `MobilerunStream` library product to your app. It pins LiveKitWebRTC to exactly
`150.7871.05` (SwiftPM normalizes the version to `150.7871.5`).

```swift
import MobilerunStream

// Create and use the session on the main actor. The provider may fetch from your API.
let session = DeviceStreamSession(credentials: {
    guard let response = try await loadStreamCredentials() else { return nil }
    return StreamCredentials(url: response.url, token: response.token)
})
session.start()
// Observe session.status and session.videoSize.
// Use DeviceStreamView(session: session, hasControl: true) in your SwiftUI hierarchy.

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
at start, on recovery, and when a token is rejected. Nil means the device is not ready; retries
remain bounded by the normal
backoff budget. Credentials are never logged by the SDK.

A closed signalling socket or failed/closed peer rebuilds both transports through the reconnect
controller, with up to six retries and exponential backoff. Every connection requests fresh RTC
configuration. Live configuration updates replace ICE servers and send an ICE-restart offer;
non-terminal state dips are suppressed for up to 15 seconds, with a deadline recheck. The host
owns app lifecycle decisions; the session installs no app lifecycle observers.

The view sends input only when its channel is open. Raw transport methods are package-only.
Hover uses channel 2 only, including its pressed-button mask; it never falls back to control
channel 1. `openURL` sends now if control is
open, otherwise queues the latest URL for the next channel opening. `screenshot` returns decoded
image bytes, or throws `StreamError` on disconnect, timeout, failure or no open socket; cancelling
the caller cancels its pending request. Timeouts use the protocol default and are capped at 24
hours.
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

## Video and input

```swift
import SwiftUI
import MobilerunStream

@MainActor
struct PhoneView: View {
    @ObservedObject var session: DeviceStreamSession
    @State private var input = DeviceStreamHandle()

    var body: some View {
        VStack {
            DeviceStreamView(session: session, hasControl: true, handle: input)
            HStack {
                Button("Keyboard") { input.showKeyboard() }
                Button("Hide keyboard") { input.hideKeyboard() }
                Button("Back") { input.sendSystemKey(.back) }
                Button("Home") { input.sendSystemKey(.home) }
                Button("Recents") { input.sendSystemKey(.recent) }
            }
        }
    }
}
```

The view uses a Metal renderer with aspect-fit video and a transparent background. Without a
track it shows nothing. `DeviceStreamUIView(session:hasControl:)` is the UIKit equivalent;
it provides the same keyboard/system-key methods.
The optional handle controls one mounted SwiftUI view and does not retain it. The app owns
session start/close and lifecycle decisions. Unmounting the view detaches its renderer without
closing the session.

Mapping uses post-rotation video dimensions (90°/270° frames swap width and height). A touch
starting in the letterbox is ignored. Moves outside are ignored; UP/CANCEL releases at the last
in-video position. Each of up to ten fingers has a stable slot, with at most one MOVE per display
frame. iPad mouse clicks use pointer −1; enable `UIApplicationSupportsIndirectInputEvents` in the
host app's Info.plist, as the example does. Pointer hover, including pressed buttons, uses the
separate lossy channel.
Mouse/trackpad scrolling uses wheel messages; a finger drag remains a touch gesture.

Tap the video to focus hardware input. Printable hardware characters inject text; navigation,
function and modifier keys inject Android keycodes. Cmd/Ctrl+V pastes the local string using
SET_CLIPBOARD; Cmd/Ctrl+M sends Menu. Modifier masks and physical HID-to-Android mapping follow
the protocol's keyboard code table. After shortcuts/control keys, any single UTF-16 character
injects text on keydown only, including control characters and unmapped physical codes.
Textless unmapped media/volume/gamepad keys pass through to the host. Numpad Enter is a control key.
Held hardware
keys repeat after 500 ms at approximately 33 ms intervals. CJK composition and non-Latin input
modes stay with the UIKit text system. `showKeyboard()` explicitly focuses a UIKit text-input
client;
marked IME text stays local until committed or finalized by UIKit. Committed Unicode text
injects text, an empty-buffer
backspace sends DEL, and return sends ENTER. Keyboard hiding only resigns this view's own responder;
it leaves the host app's input alone. Paste uses `UIPasteboard` and follows the platform's
clipboard access behavior.

`hasControl: false` keeps rendering and suppresses all local forwarding, including keyboard,
clipboard and system buttons. Switching it off cancels active input before entering display-only
mode. This is a local interaction setting; the server owns authorization. The app must explicitly
wire its own Back action to `sendSystemKey(.back)` if desired; host OS navigation is never
forwarded implicitly. While an accepted touch is active in the video, ancestor pan/swipe
gestures (including edge-back) cannot take that touch. `.home` and `.recent` send Android system
navigation key pairs.

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

[`Examples/Connection`](Examples/Connection) contains the validation app and runners; see
[`run-input.py --help`](Examples/Connection/tool/run-input.py) for the input scenario contract.

To refresh protocol fixtures:

```sh
tool/sync-conformance.sh "$(cat conformance/VERSION)" /path/to/conformance-clone
python3 tool/generate-constants.py
```

Licensed under Apache-2.0; see [LICENSE](LICENSE).
