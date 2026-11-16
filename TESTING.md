# Try the Swift SDK

Requires macOS, full Xcode 26 or later, Python 3, and an installed iOS simulator
runtime (Xcode Settings > Components). Tested with Xcode 26.2 / 27.2. Select Xcode
with `xcode-select` and complete its first-launch setup. The SDK supports iOS 15+;
Liquid Glass requires iOS 26+. SwiftPM downloads the pinned WebRTC dependency.

## Credentials and launch

Use a device in your Mobilerun account. Your backend fetches `streamUrl` and
`streamToken` via `GET /devices/{id}` and supplies them to the app. Never ship an
API key in an app. Create a JSON file outside the checkout; never commit it:

```json
{"streamUrl":"wss://your-stream-endpoint","streamToken":"your-short-lived-token"}
```

```sh
tool/run-sample.sh /path/to/credentials.json
```

The script selects the newest available iOS runtime and a compatible iPhone,
builds the existing Connection example, boots a temporary simulator, installs the
app, copies the JSON into private storage, and launches the tester screen.
Simulator.app must be installed. Keep the script running while testing; Ctrl-C
shuts down and deletes its simulator and removes its build output.

The app reads and deletes the copied file once, including invalid JSON. The original
file remains on your machine; delete it when finished. Credentials then stay only
in memory and disappear on process exit. The token field is obscured. You can also
launch the Connection scheme in Xcode and paste both fields manually. Credentials
opens the form; Connect applies changes. Reconnect creates a fresh session. This
sample reuses the supplied token; enter fresh values when it expires. Your
production backend should refresh credentials.

## What to try

Use harmless apps and existing text fields on the remote device. Changes persist
on that device. Every row includes the expected result.

| Try | Expected result |
|---|---|
| Connect / first frame | Connecting gives way to live video with preserved aspect ratio. |
| Tap | The remote control responds, including near the picture's edges. |
| Swipe | A scrollable remote page scrolls in the drag direction. |
| Two fingers | A zoomable page zooms. Hold Option in Simulator for pinch; gesture support depends on host configuration. |
| Soft keyboard | Enable Keyboard mode, focus a remote text field, and tap Keyboard to show Simulator's software keyboard (disconnect its hardware keyboard if needed). Latin letters arrive per character; Backspace deletes one character and Enter sends a return. Try emoji and CJK composition too; see the known limitation below. |
| Back / Home / Recent | Each navigation button performs the corresponding remote Android action. |
| Rotate | Rotate Simulator using Device > Orientation; video stays fitted and taps remain aligned. Rotate the remote app too if it supports it. |
| Background / foreground | Go to Simulator Home, then reopen the sample; video resumes or recovers. |
| Network off / on | On a physical iPhone, disable connectivity and restore it; video recovers. Simulator cannot independently switch its network, so this requires a physical device. |
| Forced reconnect | Tap Reconnect; a fresh connection produces video again. |
| Unavailable / Retry | Connect with an invalid token and wait for attempts to exhaust; unavailable and Retry appear. Retry attempts recovery again. Restore valid credentials using Credentials and Connect. |
| Themes / labels / chrome | Light, Dark and Brand change tokens. Brand uses indigo controls, rounded cards, Go back / Start / Apps and Allow / Decline. Solid chrome toggles opaque surfaces; iOS 26+ otherwise uses Liquid Glass, subject to accessibility settings. |
| Demo approval | A 30-second countdown appears for Visa 4242 and com.example.shop. Approve or Deny removes the card and shows the decision plus refetch 2. Repeat for the other action. No real task is sent and the fake never polls. |
| Stats | Stats shows updating fps, payload kbit/s, RTT, jitter-buffer delay, ICE candidate types and first-frame ms. Unsupported values show —. Hide stats removes the subscription. |

Typical simulator values on a relay connection: first frame about 6.6 seconds, 59.9 fps, 52.8 kbit/s on a static launcher, RTT 20.6 ms and tap-to-pixel median 156.1 ms (p90 183.6 ms).

## Automated checks

```sh
swift test
tool/api-dump.sh --check
xcodebuild -scheme MobilerunStream -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Examples/Connection/Connection.xcodeproj -scheme Connection \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:SampleTests -only-testing:InputUITests/SampleUITests \
  -parallel-testing-enabled NO -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO
```

Choose an installed iPhone name for the last command. Sample tests cover credential
validation, one-time deletion, token redaction and secure input, theme tokens and
labels, and local approval decisions/refetch. Library suites cover the stream,
input, countdown ticking, approvals and UI internals. Existing E2E and benchmark
runners remain under `Examples/Connection/tool/`; the native validation view uses
`--probe` and default UI validation uses `--default-ui`.

## Known limitations

Events subscription awaits the backend token contract. Publishing has not happened;
install from source. Network-switch recovery requires a physical device. Simulator
multitouch and IME support depend on host configuration.

Emoji and some CJK may not arrive on Cloud Android devices via text injection yet;
the device-side fix is pending and affects every client. This checklist item is a
known limitation, rather than a passing delivery check.
