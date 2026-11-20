← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Lifecycle

The composite observes real background→foreground and offline→online transitions.
Background pauses keep-alives; foreground resumes them and wakes pending recovery.
Initial foreground/online registration does not wake or restart a connection. Custom
UI can retain `StreamLifecycleAdapter(session:)` and call `start()`/`stop()` with its
visible lifetime, or call `setVisible(_:)`/`handleWake()` directly. Use one lifecycle
adapter for the current session; use `rebind(session:)` if it changes. `DeviceStream`
rebinds automatically. Unmounting the composite removes its observers; it does not close
the app-owned session.
