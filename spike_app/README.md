# Swift stream spike

A throwaway Swift 6 / iOS 15 sample using LiveKitWebRTC **150.7871.05**.
The package's Swift types use the `LKRTC` prefix. This is a protocol probe,
not a supported SDK or a proposed library API.

Build with Xcode 27.2, using an exclusive build-host lock when sharing the machine:

```sh
xcodebuild -project spike_app/StreamSpike.xcodeproj \
  -scheme StreamSpike -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath spike_app/DerivedData ARCHS=arm64 build-for-testing
```

Supply a local JSON file with `deviceId`, `platform`, `streamUrl`, and
`streamToken`; never commit it or pass credential values in launch arguments.
Run the disposable simulator session (including cleanup) in one lock:

```sh
python3 spike_app/tool/run_spike.py \
  "$SPIKE_CONFIG_PATH" \
  spike_app/DerivedData/Build/Products/Debug-iphonesimulator/StreamSpike.app \
  "$SPIKE_ARTIFACT_DIR" "$SPIKE_SCREENSHOT_DIR"
```

The script injects the config into the installed app's private Documents
folder, creates an iPhone simulator on the newest installed iOS runtime, and
launches a small UI test that accepts the simulator's debug-URL consent.
The test is a session helper: it is intentionally terminated during cleanup.
Commands on stdin: `connect`, `connect h264`, `tap X Y`, `close`, `restart`,
`stats`, `shot NAME`, `log`, `finish`. `restart` requests fresh RTC configuration
from the server and then applies it before making an ICE-restart offer. Tap coordinates are in points relative
to the video view; letterboxing is mapped by the same function as view taps.
Debug URLs: `spike://tap?x=…&y=…`, `spike://connect`,
`spike://connect?codec=h264`, `spike://close`, `spike://restart`, `spike://stats`.

Measurements log only selected codec/frame counters and protocol events;
URLs, credentials, ICE servers, candidates, and raw errors are not logged.
First-frame time is measured at the first **decoded frame callback**;
screenshots verify the rendered image separately. The sample uses unchecked
Sendable wrappers around the Objective-C callbacks and serializes session
operations on the main queue; production code needs explicit actor ownership.

For unsigned, uncompressed arm64 release size versus a minimal SwiftUI app:

```sh
python3 spike_app/tool/measure_size.py "$SPIKE_ARTIFACT_DIR"
```

Delete `spike_app/DerivedData` after the measurements. This sample does not
create/delete remote devices, purchase anything, or implement session retries.
