← [README](../README.md) · [Partner guide](https://docs.mobilerun.ai/partners)

# Task approvals

```swift
// Retain this @MainActor ObservableObject, e.g. as a @StateObject.
let approvals = TaskApprovalModel(
    taskId: taskId,
    fetchApproval: { taskId in try await backend.pendingApproval(taskId: taskId) },
    decide: { taskId, approvalId, decision in
        try await backend.decide(taskId: taskId, approvalId: approvalId, decision: decision)
    }
)
approvals.start()

// In an observing SwiftUI view:
TaskApprovalCard(state: approvals.state, onDecide: approvals.decide) {
    DeviceStream(session: session)
}
// On teardown:
approvals.stop()
```

Omit the `device` builder for a standalone card. Unknown kinds or malformed payment-card
details show the generic heading and still allow decisions. The card parses `label`
(falling back to `credentialName`), `targetPackage` and optional `targetHost`.
`PendingApproval` is Codable and preserves arbitrary JSON details via `JSONValue` from
`import MobilerunStream` alone. `PendingApproval.paymentCardDetails()` exposes validated payment-card
details to custom UI. Parsing/countdown free functions stay internal.

Without `subscribe`, the model polls every 3 seconds after each completed fetch.
An optional `subscribe(taskId, onChange) -> Result<Unsubscribe, Error>` replaces polling;
`Unsubscribe` returns `Result<Void, Error>`, and `onError` is non-throwing.
Subscription notifications only trigger a fetch, and the backend response remains authoritative.
Overlapping/stale fetch results and results from old tasks or disposed models are ignored.
`setTaskId(_:)` resets decision state and rebinds a model whose host requested running;
an empty task pauses work, and a subsequent nonempty task resumes it until `stop()`.

Every completed decision refetches, including 404/409 failures. Decision errors persist
until the next decision/task change; fetch errors clear on the next successful fetch.
Integrator cancellation and timeout errors are ordinary failures: deciding clears, the
error appears and the model refetches. Only the model's own stop/disposal discards
cancelled work silently. Subscription failures are reported through `onError`, and through
`state.error` until the next successful fetch. The controller falls back to polling every
3 seconds; unsubscribe failures only reach `onError` and never replace task state. `TaskApprovalState.error` is a display
string and the model retains its underlying `error` object. State and theme are Equatable.

The countdown is display-only, isolated from the card/device and stops ticking at expiry;
only the backend decides whether a late approval is accepted. Errors announce immediately
through VoiceOver. Both actions disable while deciding. Replace them with the `actions`
builder, whose `TaskApprovalActionsState` supplies `isPending`, decision and `onDecide`.
Below 768 points of card width (including padding) the card switches Details/Device;
at 768 and above it shows them side by side. Long details scroll inside their fixed-height
area. Error/actions sit below that area and remain available in either view. New approval
identifiers reset the selected view; repeated error text is announced only once until changed.
The device remains mounted through switches and width changes.

The validation example supports `--default-ui --ui-state <state>` with connecting,
reconnecting, unavailable, dark, custom, approval, approval-expired, approval-error and
live modes. Presentation-only modes do not contact a device; approval callbacks are
fake. Live mode uses the example's runtime-injected stream credentials. UI automation
covers default states, labels, approve/deny/refetch, expiry, error and device identity.
The runner also exercises a wide iPad container, narrows it below the breakpoint, and
checks that widening it again preserves the mounted device. Run `run-ui.py --help` for
evidence-directory and optional runtime credentials arguments.
