# Third-party notices

Mobilerun Swift is licensed under Apache-2.0 (see [LICENSE](LICENSE)).
That license does not replace the licenses of its dependencies.

## LiveKit WebRTC

`Package.swift` pins `livekit/webrtc-xcframework` to `150.7871.05`
(SwiftPM canonical version `150.7871.5`, revision
`7d963f6fae5921cc8e594a5fef42db2bd2ea8563`). SwiftPM downloads
`LiveKitWebRTC.xcframework.zip` from the
[upstream release](https://github.com/livekit/webrtc-xcframework/releases/tag/150.7871.05).
The binary is not checked into this SDK repository; it is linked for iOS streaming.

- Package wrapper: [MIT license](https://github.com/livekit/webrtc-xcframework/blob/150.7871.05/LICENSE), reproduced below.
- Binary archive: `LiveKitWebRTC.xcframework/LICENSE`, reproduced below, carries
  the WebRTC project’s BSD license.
- The [upstream build source](https://github.com/webrtc-sdk/webrtc-build/commit/46d23752905fe2aedd3469d378c838e242947859)
  identifies the build used for this release. WebRTC includes other third-party
  components; consult the corresponding source and its component licenses when
  assessing the contents of a redistributed binary.

### Package wrapper — MIT

```text
MIT License

Copyright (c) 2021 WebRTC SDKs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Binary archive — WebRTC BSD

```text
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## App distributors

When distributing an app containing LiveKit WebRTC, retain the applicable
copyright, license and disclaimer texts with the app’s documentation or other
materials (for example, an accessible third-party acknowledgements screen).
Include the MIT and WebRTC BSD notices above and preserve any additional notices
required by the components in the exact binary you ship. Do not assume this
SDK’s Apache-2.0 license covers WebRTC or its transitive components.

This inventory records the package license and the root license inspected in
archive `150.7871.05`; it is not a complete inventory of every embedded WebRTC
component. Review the matching source/build inputs for additional component
obligations, and refresh the notices when changing the dependency or binary.
