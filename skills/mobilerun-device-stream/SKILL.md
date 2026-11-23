---
name: mobilerun-device-stream
description: Use when integrating a live Mobilerun device stream into a Swift iOS partner app with backend-minted tokens and customizable SwiftUI controls.
---

# Mobilerun device stream for Swift

## When to use

Embed live device video and remote input in an iOS 15+ app using the
`MobilerunStream` library. Use Swift 6.2 and Xcode 26 or newer. Read the
[connection guide](../../docs/stream-keys.md) for transport details and the
[default UI guide](../../docs/default-ui.md) for custom controls.

## Backend: mint one token per connect

Keep `MOBILERUN_API_KEY` in the server environment. Authenticate your app's user
and authorize access to the requested device before minting on their behalf.
Using that API key on the server only, send:

```http
POST https://api.mobilerun.ai/v1/identity/stream-keys
Content-Type: application/json

{"deviceId":"DEVICE_ID","ttlSeconds":120,"allowedOrigins":["https://partner.example"]}
```

The response is `{key, keyId, expiresAt}`. Return `key` from your authenticated
backend endpoint without logging or caching it; use `Cache-Control: no-store`.
Tokens start with `dr_st_`, are single-use, and default to 120 seconds of validity
for admission. `ttlSeconds` controls admission expiry, not the connected session's
lifetime. An established session has a 30-minute server cap.

`allowedOrigins` is optional and binds browser use to the listed sites; it is not
a substitute for user/device authorization. Choose it for browser consumers;
do not assume a native iOS connection sends a browser Origin header.
The repository's [backend helper](../../Examples/Connection/backend/server.mjs)
shows minting through the JavaScript API SDK; its unauthenticated loopback server
is for local development only.

## Client: provide a fresh token for every attempt

`StreamTokenProvider` is `@Sendable () async throws -> String`. Put the backend
mint request inside this closure, never in a cached value outside it. The SDK
calls it before every new signalling WebSocket, including reconnects and manual
retry. Do not cache, prefetch for reuse, or return a previously consumed token.

```swift
import SwiftUI
import MobilerunStream

// App-owned factory: mintKey must call your authenticated backend each time.
@MainActor
func makeSession(deviceID: String,
                 mintKey: @escaping StreamTokenProvider) -> DeviceStreamSession {
    let streamURL = URL(string:
        "wss://api.mobilerun.ai/v1/devices/\(deviceID)/stream")!
    let session = DeviceStreamSession(credentials: {
        StreamCredentials(url: streamURL, tokenProvider: mintKey)
    })
    session.onError = { error in
        // Present recovery using error.reason and error.final.
        // error.message is sanitized; error.attempt is one-based.
    }
    session.start()
    return session
}

@MainActor
struct PhoneView: View {
    @ObservedObject var session: DeviceStreamSession
    var body: some View {
        DeviceStream(session: session)
    }
}
```

Retain the session in a main-actor owner across view remounts, rather than
constructing it in `body`. Call `session.close()` when that owner is permanently
torn down; closing is permanent. Create a new session when switching devices.
The SDK appends the token to the stream URL; do not embed one yourself.

The outer `credentials` callback discovers the target; it is not called for
every socket. Its returned `StreamCredentials.tokenProvider` performs per-socket
minting. Provider mode requires `wss` (local loopback `ws` is allowed for development).
If both a static token and provider are supplied, the provider wins with no fallback.

## Errors and recovery

`session.onError` runs on the main actor for each failed attempt with a
`StreamConnectionError`: `reason`, `message`, `attempt`, and `final`.
`session.lastError` exposes the same error and clears after a successful connection.
`reason` is a `StreamErrorReason`; the wire-style strings below are its `rawValue`.

| Swift case / raw value | Meaning and action |
| --- | --- |
| `.credentialsUnavailable` / `credentials_unavailable` | Provider threw, exceeded 10 seconds, returned blank output, or targeted an unsafe endpoint. Fix backend authentication/availability or the URL; never fall back to a static token. |
| `.connectionRefused` / `connection_refused` | Socket failed before opening: wrong device, refused origin (403), 404, other statuses, or network failure. Check device URL, origin policy and connectivity. |
| `.tokenRejected` / `token_rejected` | Upgrade returned 401. Check for used, expired or revoked tokens; mint a fresh token on the next attempt. |
| `.disconnected` / `disconnected` | An open session dropped or its peer failed, including the 30-minute cap. Let SDK recovery connect with a fresh token. |
| `.deviceUnavailable` / `device_unavailable` | Reserved for an explicit server offline/not-ready indication. Check device readiness; never infer this reason from timeouts or HTTP status alone. |
| `.unknown` / `unknown` | Other failure, including the connection watchdog or missing configuration after opening. Inspect sanitized diagnostics and connection setup. |

Normal backoff applies to provider failures too. Failures 1–6 are non-final;
failure 7 is final. `final == true` means automatic retries stopped. The default
UI exposes Retry; custom UI should call `session.retry()` after the underlying
problem is resolved to start a fresh budget. Do not add a competing reconnect loop.

## Labels and theming

`StreamLabels` has English defaults for `connecting`, `reconnecting`,
`reconnectingAttempt`, `disconnected`, `unavailable`, `retry`, `back`, `home`,
and `recent`. Preserve `{attempt}` and `{max}` placeholders in
`reconnectingAttempt` when translating it.

```swift
DeviceStream(session: session)
    .streamLabels(StreamLabels().with {
        $0.connecting = "Preparing your phone"
        $0.unavailable = "Phone unavailable"
        $0.retry = "Connect again"
    })
    .streamTheme(StreamTheme.dark.with {
        $0.primary = .indigo
        $0.primaryForeground = .white
        $0.radius = 16
        $0.typography = .body
        $0.surfaceStyle = .solid
    })
```

The default UI has no logo. Light is the default theme; use `.streamTheme(.dark)`
or `.streamThemeFollowsSystem(light: .light, dark: .dark)` explicitly.
Theme color fields are `background`, `foreground`, `card`, `cardForeground`,
`muted`, `mutedForeground`, `border`, `ring`, `primary`, `primaryForeground`,
`accent`, `accentForeground`, and `destructive`. Keep text/button contrast readable.
`surfaceStyle` controls native glass versus solid chrome; Swift uses native theme
values, not CSS variables.

For custom chrome, pass `StreamSlots(placeholder:unavailable:navigation:)` to
`DeviceStream(session:slots:)`; overlay slots receive labels, error and retry
action through `StreamOverlayState`. See the default UI guide for slot builders.

## Security rules

- Never ship the API key in an app, client configuration, bundle, or browser.
- A stream token grants view and control of one device: first connect consumes
  the token; expiry prevents unused tokens from connecting. Treat it as a secret,
  including query strings, logs, analytics, screenshots and crash reports.
- Token expiry does not terminate an already established session.
- Authorize device ownership on your backend for every mint request. Client UI
  controls are not an authorization boundary.
- Legacy `StreamCredentials(url:token:)` is deprecated and only for existing
  integrations until retirement. It reuses the same token on reconnect and logs
  one warning per session. This compatibility exception cannot support single-use
  tokens across reconnects; use `tokenProvider` for new integrations.

## Troubleshooting

- **401 at connect:** check used, expired or revoked tokens and verify origin
  policy. Swift reports a visible 401 as `token_rejected`; refused origins may
  instead return 403 and become `connection_refused`. Ensure every attempt mints
  a new key and targets the device it was minted for.
- **422 at mint:** read the response's `issues` and fix invalid request fields
  on the backend; do not retry the same invalid body unchanged.
- **Provider failures:** check your authenticated backend endpoint, response
  decoding and latency. Return only the nonblank `key` string, not the whole
  response. A throw or 10-second deadline yields `credentials_unavailable`;
  the SDK opens no socket for that attempt and ignores late provider results.
