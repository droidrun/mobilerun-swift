← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Default UI

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
starts and closes the session. One control setting, enabled while the session is open and available,
is passed to both video input and navigation. Display-only mode keeps video visible.
The backend remains responsible for authorization.

Light tokens are the default, regardless of the phone's appearance. Opt into dark with
`.streamTheme(.dark)`, or explicitly follow the host with `.streamThemeFollowsSystem(light: .light, dark: .dark)` (both palettes are customizable).
Every React semantic color token is available: background, foreground, card,
cardForeground, muted, mutedForeground, border, ring, primary, primaryForeground,
accent, accentForeground and destructive. `radius` is the base radius, defaulting to 8 points. Buttons use `radius × 0.75`
and cards use `radius + 4`, giving 6-point buttons and 12-point cards by default;
`typography` controls the component font.
Defaults convert the React CSS OKLCH values once using CSS Color 4's OKLab-to-linear-sRGB
matrix and sRGB transfer function, clamping out-of-gamut channels to [0, 1]. The dark
border preserves the source's 10% white alpha. Colors are stored as gamma-encoded sRGB.

`StreamLabels` contains stream/navigation labels; `TaskApprovalLabels` independently
contains approval labels via `.taskApprovalLabels(_:)`. `connecting` replaces React's
`placeholderLabel`; reconnect attempts accept `{attempt}` and `{max}` (`ReconnectPolicy.maxAttempts` is 6); countdown accepts
`{time}`. Theme, both label types and slots support `with { ... }` copies. SDK-created values have no public constructors or copy helpers. The default `.subheadline` font
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

Each overlay receives one `StreamOverlayState` with status, labels, video presence
and retry action; builders inherit theme through the environment and read labels from the state. Navigation and approval actions each
receive one state object. `StreamStatusPill`, `StreamNavigationBar`, `StreamPlaceholder`
and `StreamUnavailableView` can also be used independently.

## Liquid Glass chrome

On iOS 26+, chrome uses native Liquid Glass by default: the status pill and retry card
use themed glass surfaces, navigation uses one glass-effect container, and Retry/Approve
use prominent glass buttons. Secondary approval and navigation actions use glass buttons.
The video renderer never receives a glass effect. While reconnecting retains video, the
placeholder has an opaque theme background so glass cannot sample it; the phone glyph
appears only when no video is available.

Set `.streamTheme(.light.with { $0.surfaceStyle = .solid })` to keep opaque chrome,
or apply the same override to `.dark`. Theme tokens still supply tint and text colors.
The deployment target remains iOS 15; earlier systems use solid styling.
Reduce Transparency and Increase Contrast dynamically select the opaque token-based
fallback for readable controls, including when preferences change while mounted.
