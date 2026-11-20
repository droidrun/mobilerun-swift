← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Stream statistics and benchmark

`session.statsPublisher` publishes read-only `StreamStats?` reports sampled once per second while connected,
foreground and subscribed. Use `sink` or SwiftUI `onReceive(session.statsPublisher)` and retain the subscription
for the desired measurement lifetime. Cancelling the last subscriber stops native sampling and clears
`stats`. It also becomes nil when hidden, disconnected or closed, including transient peer dips
hidden by the public ICE-restart grace period. Each connection attempt resets
first-frame timing and rate baselines. The session's lifecycle owner calls `setVisible(_:)`;
the default UI already does this. The publisher completes when the session closes. Statistics
updates do not emit session-wide `objectWillChange` notifications; observe the publisher for samples.

Samples include FPS, decoded width/height, codec MIME type, inbound video `bitrateKbps`, selected
ICE pair `rttMs`, jitter-buffer delay and decode time per frame, cumulative packets lost,
frames dropped and freezes, separate local/remote candidate types, and `timeToFirstFrameMs`.
Durations are milliseconds; missing fields are nil. Bitrate, fallback FPS and per-frame durations
use consecutive counter deltas, so the first sample and reset counters have no rates. Values
contain no endpoints or credentials. The SDK creates `StreamStats`; new fields can be added
without requiring callers to change an initializer.

The Debug connection example supports a repeatable simulator benchmark. Run from the repository root:

```sh
tool/benchmark.sh --credentials /path/to/runtime-credentials.json \
  --evidence /path/to/results --tap-x 0.5 --tap-y 0.9
```

The runtime JSON has `streamUrl` and `streamToken`. Choose the normalized upright-video position
of a known launcher icon that changes when tapped; coordinates above are only an example.
The script creates five connections with ten fresh stats samples and ten tap samples each,
then writes `benchmark-results.md` and raw samples outside the repository. It removes credentials,
the simulator and DerivedData on exit. Tap detection uses the maximum tile mean absolute luma
difference in a 64×64-pixel region around the input, with a separate central region for app launch.
It timestamps the native video-renderer callback, before compositor/display presentation, so
reported input-to-pixel timing excludes display scanout. Do not compare it directly with
camera-measured glass-to-glass latency.
