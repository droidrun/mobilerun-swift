# Try the Swift SDK

Requires macOS, full Xcode 26 or later, Python 3, and an installed iOS simulator
runtime (Xcode Settings > Components). Tested with Xcode 26.2 in CI. Select Xcode
with `xcode-select` and complete its first-launch setup. The SDK supports iOS 15+;
Liquid Glass requires iOS 26+. SwiftPM downloads the pinned WebRTC dependency.

## Credentials and launch

Use an existing device in your Mobilerun account. The preferred launch file contains no credentials:

```json
{"helperBaseUrl":"http://localhost:3001","deviceId":"DEVICE_UUID"}
```

Start the unauthenticated **local-only** development helper in `Examples/Connection/backend`:

```sh
npm ci
# Set MOBILERUN_API_KEY securely in this process environment before starting.
npm start
```

Requires Node 22 or later. It binds 127.0.0.1:3001; never expose it through a tunnel.
The helper only answers loopback Host headers for its listening port and requests without Origin.
`MOBILERUN_API_URL` optionally selects your server-side API base (ending in `/v1`).
Production backends must authenticate callers and authorize access to the requested device.
No API key belongs in app launch JSON, app state, storage or logs.

```sh
tool/run-sample.sh /path/to/launch.json
```

The runner builds the Connection example, boots an owned temporary simulator, copies the JSON
into private app storage and launches it. Ctrl-C shuts down and deletes that simulator and
its build output. The app reads and deletes the copied JSON once, including malformed JSON;
the original file remains on your machine. The sample captures helper/device configuration
immutably for each session. Reconnect creates a new session bound to the same target.

Discovery GET `/api/v1/devices/:deviceId` returns only `{id,state,streamUrl}`. The target's
`tokenProvider` POSTs `/api/v1/devices/:deviceId/stream-key` once per new socket. The helper uses
`@mobilerun/sdk@6.3.0` to call `sdk.streamTokens.create({deviceId,ttlSeconds:120},{maxRetries:0})`.
The upstream wire endpoint is POST `/identity/stream-keys` on the `/v1` API base.
Its response is only `{key,keyId,expiresAt}`;
all responses disable caching. The app uses only the key transiently and stores none of these
mint fields. The sample's local HTTP allowance does not relax provider-mode stream WSS policy.

The existing manual form and file remain a **legacy diagnostic** path:

```json
{"streamUrl":"wss://your-stream-endpoint","streamToken":"your-static-token"}
```

The token field is obscured. Credentials opens the form; Connect applies its values.
A pasted single-use key cannot reconnect; prefer the backend flow. When changing devices,
launch a new helper/device configuration so a new session captures the new device.

## What to try

Use harmless apps and existing text fields on the remote device. Changes persist
on that device. Every row includes the expected result.

| Try | Expected result |
|---|---|
| Connect / first frame | Connecting gives way to live video with preserved aspect ratio. |
| Tap | The remote control responds, including near the picture's edges. |
| Swipe | A scrollable remote view scrolls in the drag direction. |
| Two fingers | A zoomable view zooms. Hold Option in Simulator for pinch; gesture support depends on host configuration. |
| Soft keyboard | Focus a remote text field and tap Keyboard to show Simulator's software keyboard (disconnect its hardware keyboard if needed). Latin letters arrive per character; Backspace deletes one character and Enter sends a return. Try emoji and CJK composition too; see the known limitation below. |
| Back / Home / Recent | Each navigation button performs the corresponding remote Android action. |
| Rotate | Rotate Simulator using Device > Orientation; video stays fitted and taps remain aligned. Rotate the remote app too if it supports it. |
| Background / foreground | Go to Simulator Home, then reopen the sample; video resumes or recovers. |
| Network off / on | On a physical iPhone, disable connectivity and restore it; video recovers. Simulator cannot independently switch its network, so this requires a physical device. |
| Forced reconnect | Tap Reconnect; a fresh connection produces video again. |
| Unavailable / Retry | Connect with an invalid token and wait for attempts to exhaust; unavailable and Retry appear. Retry attempts recovery again. Restore valid credentials using Credentials and Connect. |
| Themes / labels / chrome | Light, Dark and Brand change tokens. Brand uses indigo controls and rounded cards. Go back / Start / Apps are navigation accessibility labels; Try again is the visible retry label. Approval buttons show Allow / Decline. Solid chrome toggles opaque surfaces; iOS 26+ otherwise uses Liquid Glass, subject to accessibility settings. |
| Demo approval | A 30-second countdown appears for Visa 4242 and com.example.shop. Approve or Deny removes the card and shows the decision plus refetch 2. Repeat for the other action. No real task is sent and the fake never polls. |
| Stats | Stats shows updating fps, payload kbit/s, RTT, jitter-buffer delay, ICE candidate types and first-frame ms. Unsupported values show —. Hide stats removes the subscription. |

Reference ranges from the [benchmark runner](tool/benchmark.sh) on a simulator relay connection: first frame 6–7 seconds, 59–61 fps, 50–55 kbit/s on a static launcher, RTT 20–25 ms and tap-to-pixel median 150–160 ms (p90 180–190 ms).

## Automated checks

```sh
swift test --filter sessionTokenProvider
swift test
swift build -c release
tool/api-dump.sh --check
xcodebuild -scheme MobilerunStream -destination 'generic/platform=iOS Simulator' \
  -configuration Release -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Examples/Connection/Connection.xcodeproj -scheme Connection \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:SampleTests -only-testing:InputUITests/SampleUITests \
  -parallel-testing-enabled NO -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO
```

Run `npm ci && node --test server.test.mjs` in `Examples/Connection/backend` for the
actual local HTTP helper boundary. Provider tests cover the 9999/10000ms deadline,
uncooperative/blocking callbacks, stale results, URL policy and full socket watchdog budget.
A real loopback WebSocket test sends close 1001 through URLSession on Simulator.
API baseline generation uses Xcode 26.2; newer Xcode can build and test, but its symbol graph
must not replace that baseline. Conformance token-provider replay awaits an approved fixture tag.

Choose an installed iPhone name for the last command. Sample tests cover credential
validation, one-time deletion, token redaction and secure input, theme tokens and
labels, and local approval decisions/refetch. Library suites cover the stream,
input, countdown ticking, approvals and UI internals.

## Known limitations

Publishing has not happened; install from source. Network-switch recovery requires a
physical device. Simulator multitouch and IME support depend on host configuration.

Some emoji and CJK characters may not arrive on Cloud Android devices through text injection.
