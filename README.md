# mobilerun-swift

Pre-release Swift libraries for live Mobilerun device streams. Requires Swift 6.0 or newer.
The connection library supports iOS 15+; `MobilerunProtocol` also supports macOS 13+.

- `MobilerunStream`: observable session, SwiftUI/UIKit video and input, and native WebRTC on iOS.
- `MobilerunProtocol`: binary control encoders, typed signalling and protocol constants.

## Installation (after first release)

No release is available yet. After `v0.1.0` is released, add:

```swift
.package(url: "https://github.com/droidrun/mobilerun-swift.git", .upToNextMinor(from: "0.1.0"))
```

Until 1.0, constrain upgrades to the next minor version as shown above.
Choose `MobilerunStream` for the iOS SDK or `MobilerunProtocol` for standalone wire
helpers. See [RELEASING.md](RELEASING.md) for the API contract and release process.

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
at start, on recovery, and when a token is rejected. Nil means the device is not ready;
the engine alone polls at 3,000 ms only until the first target is found (a thrown provider
error also counts as not ready). Each provider call is bounded by the connection timeout.
Remounts reuse the newest cached target; a heal refreshes it in the background and survives
remounts. Nil or failed refreshes preserve that cache, and connection failures still consume
the retry budget until unavailable/Retry. Pass your integrator backend call directly as the
provider; no separate credentials helper is needed.
The API key must stay on your backend and must never ship inside an app. Credentials are never logged by the SDK.

A closed signalling socket or failed/closed peer rebuilds both transports through the reconnect
controller, with up to six retries and exponential backoff. Every connection requests fresh RTC
configuration. Live configuration updates replace ICE servers and send an ICE-restart offer;
non-terminal state dips are suppressed for up to 15 seconds, with a deadline recheck. The host
owns app lifecycle decisions; the session installs no app lifecycle observers. The optional
default UI installs an adapter for its visible lifetime (see below).

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
Mapped fallback keys with no printable text send paired DOWN/UP keycodes; releases follow the
original keydown route even if the produced text changes. Textless unmapped keys pass through
to the host. Numpad Enter is a control key. Held hardware keys repeat after 500 ms at approximately
33 ms intervals. CJK composition and non-Latin input
modes stay with the UIKit text system. `showKeyboard()` explicitly focuses a UIKit text-input
client using a normal text keyboard, with correction, spell checking, smart substitutions and
predictions disabled. CJK and emoji remain available. Marked IME text stays local until committed or
finalized by UIKit. Committed Unicode text
injects text, an empty-buffer backspace sends DEL, and return sends ENTER. Keyboard hiding only
resigns this view's own responder;
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

## Default UI

```swift
DeviceStream(session: session, hasControl: true) // optional showsNavigation: false
    .streamLabels(StreamLabels().with {
        $0.connecting = "Preparing your phone"
        $0.retry = "Try again"
    })
    .streamTheme(StreamTheme.light.with {
        $0.primary = .indigo
        $0.radius = 16
    })
```

`DeviceStream` composes the native video/input view, a connecting/reconnecting pill,
retry view and Back/Home/Recent navigation. It has no logo or branding. The host still
starts and closes the session. A single `canControl = hasControl && status != unavailable`
is passed to both video input and navigation. Display-only mode keeps video visible.
The backend remains responsible for authorization.

Light tokens are the default, regardless of the phone's appearance. Opt into dark with
`.streamTheme(.dark)`, or explicitly follow the host with `.streamThemeFollowsSystem(light: .light, dark: .dark)` (both palettes are customizable).
Every React semantic color token is available: background, foreground, card,
cardForeground, muted, mutedForeground, border, ring, primary, primaryForeground,
accent, accentForeground and destructive. `radius` controls card corners;
`typography` controls the component font. Buttons use React's 6-point radius.
Defaults convert the React CSS OKLCH values once using CSS Color 4's OKLab-to-linear-sRGB
matrix and sRGB transfer function, clamping out-of-gamut channels to [0, 1]. The dark
border preserves the source's 10% white alpha. Colors are stored as gamma-encoded sRGB.

`StreamLabels` contains stream/navigation labels; `TaskApprovalLabels` independently
contains approval labels via `.taskApprovalLabels(_:)`. `StreamLabels.statusLabel(_:)`
formats the connecting/reconnecting placeholder. `connecting` replaces React's
`placeholderLabel`; reconnect attempts accept `{attempt}` and `{max}`; countdown accepts
`{time}`. Theme, both label types and slots support `with { ... }` copies. Other value
types use explicit initializers with defaulted fields. The default `.subheadline` font
scales with Dynamic Type.

Replace any piece using `StreamSlots`; each builder defaults to the matching component:

```swift
let slots = StreamSlots(
    placeholder: { context in
        AnyView(Text("Preparing a device").frame(maxWidth: .infinity))
    },
    unavailable: { context in
        AnyView(Button("Connect again", action: context.retry))
    },
    navigation: { state in
        AnyView(Button("Home") { state.onAction(.home) }.disabled(!state.canControl))
    }
)
DeviceStream(session: session, slots: slots)
```

The overlay context contains status, video presence and retry action; builders
inherit theme/labels through the environment. Navigation and approval actions each
receive one state object. `StreamStatusPill`, `StreamNavigationBar`, `StreamPlaceholder`
and `StreamUnavailableView` can also be used independently.

The composite observes real background→foreground and offline→online transitions.
Background pauses keep-alives; foreground resumes them and wakes pending recovery.
Initial foreground/online registration does not wake or restart a connection. Custom
UI can retain `StreamLifecycleAdapter(session:)` and call `start()`/`stop()` with its
visible lifetime, or call `setHidden(_:)`/`handleWake()` directly. Use one lifecycle
adapter for the current session; use `rebind(session:)` if it changes. `DeviceStream`
rebinds automatically. Unmounting the composite removes its observers; it does not close
the app-owned session.

## Task approvals

```swift
// Retain this @MainActor ObservableObject, e.g. as a @StateObject.
let approvals = TaskApprovalModel(
    taskId: taskId,
    fetchApproval: { taskId in try await backend.pendingApproval(taskId: taskId) },
    decide: { taskId, approvalId, decision in
        try await backend.decide(taskId: taskId, approvalId: approvalId, decision: decision)
    }
)
approvals.start()

// In an observing SwiftUI view:
TaskApprovalCard(state: approvals.state, onDecide: approvals.decide) {
    DeviceStream(session: session)
}
// On teardown:
approvals.stop()
```

Omit the `device` builder for a standalone card. Unknown kinds or malformed payment-card
details show the generic heading and still allow decisions. The card parses `label`
(falling back to `credentialName`), `targetPackage` and optional `targetHost`.
`PendingApproval` is Codable and preserves arbitrary JSON details via `JSONValue` from
`MobilerunProtocol`. `PendingApproval.paymentCardDetails()` exposes validated payment-card
details to custom UI. Parsing/countdown free functions stay internal.

Without `subscribe`, the model polls every 3 seconds after each completed fetch.
An optional `subscribe(taskId, onChange) -> Result<Unsubscribe, Error>` replaces polling;
`Unsubscribe` returns `Result<Void, Error>`, and `onError` is non-throwing.
events only trigger a fetch, and the backend response remains authoritative.
Overlapping/stale fetch results and results from old tasks or disposed models are ignored.
`setTaskId(_:)` resets decision state and rebinds a model whose host requested running;
an empty task pauses work, and a subsequent nonempty task resumes it until `stop()`.

Every completed decision refetches, including 404/409 failures. Decision errors persist
until the next decision/task change; fetch errors clear on the next successful fetch.
Integrator cancellation and timeout errors are ordinary failures: deciding clears, the
error appears and the model refetches. Only the model's own stop/disposal discards
cancelled work silently. Subscription failures publish an error; unsubscribe failures
only reach `onError` and never replace task state. `TaskApprovalState.error` is a display
string and the model retains its underlying `error` object. State and theme are Equatable.

The countdown is display-only, isolated from the card/device and stops ticking at expiry;
only the backend decides whether a late approval is accepted. Errors announce immediately
through VoiceOver. Both actions disable while deciding. Replace them with the `actions`
builder, whose `TaskApprovalActionsState` supplies deciding/decision and `onDecide`.
Below 768 points of card width (including padding) the card switches Details/Device;
at 768 and above it shows them side by side. Long details scroll inside their fixed-height
area. Error/actions sit below that area and remain available in either tab. New approval
identifiers reset the selected tab; repeated error text is announced only once until changed.
The device remains mounted through switches and width changes.

The validation example supports `--default-ui --ui-state <state>` with connecting,
reconnecting, unavailable, dark, custom, approval, approval-expired, approval-error and
live modes. Presentation-only modes do not contact a device; approval callbacks are
fake. Live mode uses the example's runtime-injected stream credentials. UI automation
covers default states, labels, approve/deny/refetch, expiry, error and device identity.
The runner also exercises a wide iPad container, narrows it below the breakpoint, and
checks that widening it again preserves the mounted device. Run `run-ui.py --help` for
evidence-directory and optional runtime credentials arguments.

### Liquid Glass chrome

On iOS 26+, chrome uses native Liquid Glass by default: the status pill and retry card
use themed glass surfaces, navigation uses one glass-effect container, and Retry/Approve
use prominent glass buttons. Secondary approval and navigation actions use glass buttons.
The video renderer never receives a glass effect. While reconnecting retains video, the
placeholder has an opaque theme background so glass cannot sample it; the phone glyph
appears only when no video is available.

Build the iOS UI with Xcode 26 or later (the iOS 26 SDK); the app deployment target
remains iOS 15.

Set `.streamTheme(.light.with { $0.surfaceStyle = .solid })` to keep opaque chrome,
or apply the same override to `.dark`. Theme tokens still supply tint and text colors.
The deployment target remains iOS 15; earlier systems use the existing solid styling.
Reduce Transparency and Increase Contrast dynamically select the opaque token-based
fallback for readable controls, including when preferences change while mounted.
