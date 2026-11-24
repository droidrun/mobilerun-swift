← [README](../README.md) · [Default UI](default-ui.md)

# Microphone and camera publication

Publication sends your user's microphone and optionally camera into the remote device's virtual
inputs. Viewing and received-audio mute remain independent. The existing authenticated viewer
connection carries both signaling and media; no second stream key or REST publish request is needed.

Fetch the device's `GET /v1/devices/{deviceId}/capabilities` response through your backend and pass
its `.capabilities` values when creating the session. A stream key cannot call that endpoint. Keep
privileged API keys on your backend. Capabilities describe device support; the server still authorizes
each publish request, including view-only sessions.

```swift
let capabilities = DevicePublishCapabilities(
    microphoneInjection: true,
    cameraInjection: true,
    mediaInjectionTransport: "direct"
) // Use this device's actual backend response, not hard-coded support.
let session = DeviceStreamSession(credentials: credentialsProvider,
    config: StreamConfig(publishCapabilities: capabilities))
DeviceStream(session: session) // Floating microphone/camera pill, bottom centre.
// DeviceStream(session: session, showsPublishControls: false) for custom controls.
```

The embedding application's Info.plist must contain nonempty `NSMicrophoneUsageDescription` and,
for video, `NSCameraUsageDescription` strings explaining why access is needed. The SDK checks all
required metadata before protected APIs, then checks/requests access only after the device accepts an explicit start. Audio-only
never requests camera permission. Connect and wait for `session.status == .connected` first.

```swift
// Invoke from a user action, on the main actor.
do {
    let active = try await session.startPublish(PublishOptions(audio: true, video: true))
    // Returns only after server active and both local tracks have attached.
    print(active.phase)
} catch let failure as PublishFailure {
    // Branch on failure.reason / failure.detail, never the English message.
    switch failure.reason {
    case .permissionDenied: break // Explain permission settings in your app.
    case .publishNotAllowed: break // The server refused publication.
    default: break
    }
}
await session.stopPublish() // Idempotent; stops local capture without closing the viewer.
```

Observe `session.$publishState`: `idle → starting → accepted → capturing → active`, followed by
`stopped` or `error`. State is separate from viewer status. `startPublish` throws `PublishFailure`;
`onError` additionally reports `operation == "publish"`, the current viewer attempt, `final == true`,
and optional `mediaSessionId`, `detail` and `serverReason`. Explicit stop cancels a pending start with
`publish_cancelled`, leaves state `stopped` / `stopped_by_client`, and emits no error callback.
If the stop write itself fails, the result is `disconnected` instead.

Only audio and audio+video are supported. `audio: false` fails locally with `publish_failed` /
`invalid_options`. Camera requires device support and a compatible local H.264 encoder; it never
silently falls back to audio. One pending or active publication is allowed. To change kinds, await
stop, then explicitly start again. The pill performs this stop/start when toggling camera; stopping
microphone stops both inputs. Active controls use the theme's destructive/red color.

The first viewer offer reserves separate trackless upstream sections without prompting. The SDK sends `publishStart` before requesting permissions or capture. Capture starts only after
acceptance, then attaches to the reserved senders. Missing or unusable reservations fail `publish_unsupported`.
The SDK never adds media sections dynamically or rewrites SDP to manufacture SSRCs.

`forbidden` maps to `publish_not_allowed`; `busy` to `publish_busy`. No acceptance in 5 seconds means
`publish_unsupported` / `response_timeout`, never an inferred authorization denial. Acceptance without
capture and active completion within 30 seconds of acceptance means `publish_timeout` / `active_timeout`.
That window includes OS permission prompts. Stop can cancel a pending request; late permission/capture
results cannot restart publication. Refusal or silence never prompts or captures.

Stop, close, renderer unmount, capture loss and socket/peer replacement release SDK-owned media.
Renderer replacement/remount emits a terminal `disconnected` publish state and error once.
The session stops publication when the app backgrounds, including headless use without a lifecycle adapter. No automatic retry or reconnect
resume occurs; explicitly start again after reconnect. A same-peer ICE credential refresh preserves the
current publication. Background capture is not supported. A throwing signaling send reports
`disconnected` and releases capture, including a failed stop write.

Customize `StreamLabels` fields `microphone`, `camera`, `stopMicrophone`, `stopCamera`, `publishStarting`,
`publishPermissionDenied`, `publishNotAllowed` and `publishFailed` through `.streamLabels(...)`.
Without a direct microphone-capability snapshot the pill is absent. Camera appears only when both device
and local encoder support it. `showsPublishControls: false` hides the pill without disabling headless methods.

Real microphone/camera injection, permission dialogs and hardware interruptions require verification on
a physical iOS device and a media-capable test target. Simulator tests verify signaling, cleanup,
capability/label rules and generated native offer structure; they do not prove remote injection.

## Development checks

`swift test --filter Publish` covers fake signaling/capture and deterministic deadlines. Simulator
`NativePublishTests` checks actual offer ordering, SSRCs and codec envelopes without capture.
`DefaultUITests` includes publish click-through, labels and 375/1280-point layout captures.

The sample's `--default-ui --ui-state publish-idle` mode offers controls without a transport;
pressing them demonstrates readiness failure without prompting or sending media. Other offline modes
are `publish-hidden`, `publish-active`, `publish-starting`, `publish-permission` and `publish-forbidden`.
The `publish-narrow-before` / `publish-narrow-after` and `publish-wide-before` / `publish-wide-after`
modes provide the fixed-size layout captures. Wide UI tests require an iPad simulator.

The pill fades to 50% opacity after three seconds without interaction. A nearby touch or pointer
restores full opacity. Only its buttons receive hits; capsule padding, gaps and the separate status
text above it pass input through to the device stream.
