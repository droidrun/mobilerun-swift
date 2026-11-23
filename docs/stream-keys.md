← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Stream keys and connection

In Xcode’s Package Dependencies, add
`https://github.com/droidrun/mobilerun-swift.git`, choose **Exact Version 0.1.0**,
and select `MobilerunStream`. Keep your API key on your backend; fetch fresh stream
credentials there. The session owner creates and starts the session, keeps it across
view remounts, and closes it on owner teardown (not view disappearance):

```swift
import MobilerunStream

let session = DeviceStreamSession(credentials: {
    guard let streamURL = try await backend.streamURL(deviceID) else { return nil }
    return StreamCredentials(url: streamURL, tokenProvider: {
        try await backend.mintStreamKey(deviceID)
    })
})
session.start() // In the main-actor session owner.
// In your SwiftUI view:
DeviceStream(session: session)
// When the owner is permanently torn down:
session.close()
```

For a SwiftPM manifest, use `.package(url: "https://github.com/droidrun/mobilerun-swift.git", exact: "0.1.0")`
and add `.product(name: "MobilerunStream", package: "mobilerun-swift")` to the app target.
This resolves the `v0.1.0` git tag once it exists and the repository is public.

Run the interactive sample and follow the checklist in [TESTING.md](../TESTING.md).
See [RELEASING.md](../RELEASING.md) for the API contract and release process.

## Connection errors

`DeviceStreamSession.onError` is called on the main actor for every failed attempt, and
`lastError` holds the latest one until the stream connects again. A `StreamConnectionError` has
`reason`, `message` (fixed text, never endpoints or credentials), `attempt` (one-based) and
`final` (true when retries stopped; `retry()` then starts a fresh cycle and reports nothing itself).

| `reason` (`rawValue`) | Raised when |
| --- | --- |
| `credentials_unavailable` | The provider threw, timed out (10 s), returned a blank key or targeted a rejected host. |
| `connection_refused` | The socket closed or failed before opening: wrong device, refused origin (403), 404, other statuses, network. |
| `token_rejected` | The upgrade answered 401: a used, expired or revoked key. |
| `disconnected` | An open session dropped, including the 30-minute session cap, or its peer failed after connecting. |
| `device_unavailable` | Reserved for an explicit server indication that the device is offline or not ready; never inferred from timeouts or statuses. |
| `unknown` | Anything else, including the 45-second watchdog and no configuration after the socket opened. |

Retries follow the budget above: failures 1–6 are non-final, failure 7 is final.

## Connection

The session is an `@MainActor ObservableObject`. Native video tracks are internal to the package.
It publishes `status` (`connecting`, `connected`,
`reconnecting(attempt:)`, or `unavailable`) and `videoSize` (raw frame width,
height and clockwise rotation). `start()` is idempotent; `close()` is permanent. After close, status is no longer updated and controls are disabled. Call `retry()` when
unavailable to start a fresh retry budget and fetch fresh credentials. The credentials-discovery callback runs
at start, on recovery, and when a token is rejected. Nil means the device is not ready;
the engine alone polls at 3,000 ms only until the first target is found (a thrown provider
error also counts as not ready). Each discovery call is bounded by the 45-second connection timeout.
Remounts reuse the newest cached target; a heal refreshes it in the background and survives
remounts. Nil or failed refreshes preserve that cache, and connection failures still consume
the retry budget until unavailable/Retry. Pass your integrator backend call directly as the
provider; no separate credentials helper is needed. A legacy static-token refresh while connected is
stored for the next mount; a changed URL, or changed static token while disconnected,
remounts immediately once pending recovery permits it. A nil or empty token leaves the
stream URL unchanged; supplied tokens are percent-encoded, including `+`.
The API key must stay on your backend and must never ship inside an app. Credentials are never logged by the SDK.

Prefer `StreamCredentials(url:tokenProvider:)`: the callback is bound to that target and supplies
one fresh key before **every new signalling socket**, including retries in one recovery cycle,
wake and manual retry. Target discovery above keeps its existing recovery semantics; it is not
a per-socket mint callback. Callback-only updates do not restart healthy media and the next
attempt uses the latest target's callback. Recreate a session when switching devices.

Provider mode requires `wss` with a host; `ws` is allowed only for exact `localhost`, `127.0.0.1`
or IPv6 loopback. Unsafe endpoints fail before the callback runs. Throwing, blank output or the
independent **10-second** provider deadline counts one attempt failure, opens no socket and
never falls back to a static or embedded URL token. Nonblank keys retain their original bytes.
Stopping, dropping or replacing an attempt ignores late results without waiting for provider
cancellation. The **45-second** connection watchdog starts at socket allocation; the existing
15-second WebSocket-open and subsequent 15-second RTC-configuration budgets remain separate.
ICE refresh and keepalive on an existing socket never mint another key.

`tokenProvider` is the recommended form. The static `token` path is legacy and deprecated until
the legacy token hard cut, and remains source compatible, including nil/empty behavior. It is an
explicit exception to the no-reuse rule: every reconnect reuses the same static token and the SDK
logs one warning per session. Stream keys are single-use, so a pasted key cannot support reconnect;
single-use keys need the provider.
Your backend mints via `POST /v1/identity/stream-keys` with `{deviceId,ttlSeconds:120}`;
the API key stays on that backend. The optional TTL controls admission, while the stream
session cap is 30 minutes. Close **1001** immediately releases the peer, channels, media,
timers and pending screenshots, then schedules bounded reconnect in provider and static mode.
Other closes retain the SDK's existing full-rebuild behavior.

A closed signalling socket or failed/closed peer rebuilds both transports through the reconnect
controller, with up to six retries and exponential backoff. Every connection requests fresh RTC
configuration. Live configuration updates replace ICE servers and send an ICE-restart offer;
non-terminal state dips are suppressed for up to 15 seconds, with a deadline recheck. The host
owns app lifecycle decisions; the session installs no app lifecycle observers. The optional
default UI installs an adapter for its visible lifetime (see the default UI guide).

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
so the SDK cannot request zero playout delay.

All sessions share one peer connection factory, initialized lazily on the main actor and retained
for the process lifetime. `close()` releases the session's WebSocket, peer, data channels, timers,
requests and media references. Dropping the session also tears down its transports; explicit close
is recommended for deterministic release.

### Using alongside other WebRTC SDKs

All stream sessions share the process-wide WebRTC audio session. Changing mute state
also changes that shared audio gate, which can affect another SDK using the same framework.
SwiftPM pins LiveKitWebRTC exactly to `150.7871.05`; dependencies sharing it must resolve
to that version.
