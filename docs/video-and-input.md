← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Video and input

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
Both `DeviceStreamView` and the default `DeviceStream(session:handle:)` composite accept
the optional handle. The handle controls one mounted SwiftUI view and does not retain it. The app owns
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
the protocol's keyboard code table. After shortcuts/control keys, one UTF-16 character or one printable extended grapheme cluster
injects text on keydown only, preserving emoji and combining sequences without normalization.
Physical Enter/Tab and other control keys always use keycodes, even when UIKit produces control text.
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
