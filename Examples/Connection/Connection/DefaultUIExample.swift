// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import SwiftUI
import MobilerunProtocol
@testable import MobilerunStream

private enum ExampleFailure: LocalizedError {
    case decision
    var errorDescription: String? { "The decision could not be sent. Try again." }
}

/// Local approvals use fake backend callbacks. Stream credentials are read only by ConnectionProbe.
@MainActor final class DefaultUIProbe: ObservableObject {
    let connection = ConnectionProbe()
    let approval: TaskApprovalModel
    let mode: String
    @Published var receivedDecision = ""
    @Published var deviceMounts = 0
    @Published var narrow = false
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--ui-state")
        mode = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "connecting"
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(mode == "approval-expired" ? -1 : 65))
        let pending = PendingApproval(approvalId: "example", kind: "payment_card", details: [
            "label": .string("Visa 4242"), "targetPackage": .string("com.example.shop"), "targetHost": .string("example.com")
        ], expiresAt: expiresAt)
        var finished = false
        let fail = mode == "approval-error"
        approval = TaskApprovalModel(taskId: "example", fetchApproval: { _ in finished ? nil : pending }, decide: { _, _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            if fail { throw ExampleFailure.decision }
            finished = true
        })
    }
    func start() {
        if mode == "live" { connection.session.start() }
        else if mode == "unavailable" { connection.session.presentForTesting(.unavailable) }
        else if mode == "reconnecting" { connection.session.presentForTesting(.reconnecting(attempt: 3)) }
        approval.start()
    }
    func decide(_ decision: ApprovalDecision) {
        receivedDecision = decision.rawValue
        approval.decide(decision)
    }
}

@MainActor struct DefaultUIExample: View {
    @StateObject private var probe = DefaultUIProbe()
    var body: some View {
        content
            .streamTheme(probe.mode == "dark" ? .dark : probe.mode == "custom" ? .light.with {
                $0.background = Color(red: 0.9, green: 0.95, blue: 1)
                $0.primary = Color(red: 0.15, green: 0.25, blue: 0.5)
                $0.radius = 20
            } : .light)
            .streamLabels(probe.mode == "custom" ? StreamLabels().with {
                $0.connecting = "Connecting your phone"; $0.back = "Go back"; $0.retry = "Try again"
            } : StreamLabels())
            .onAppear { probe.start() }
            .onDisappear { probe.approval.stop(); probe.connection.session.close() }
    }
    @ViewBuilder private var content: some View {
        if probe.mode.hasPrefix("approval") {
            ApprovalExample(probe: probe, model: probe.approval)
        } else {
            DeviceStream(session: probe.connection.session, hasControl: probe.mode != "display-only")
                .onReceive(probe.connection.session.$status) { probe.connection.mark("status \($0)") }
                .onReceive(probe.connection.session.$videoSize) { size in
                    if size != nil { probe.connection.mark("frame received") }
                }
        }
    }
}

@MainActor private struct ApprovalExample: View {
    @ObservedObject var probe: DefaultUIProbe
    @ObservedObject var model: TaskApprovalModel
    var body: some View {
        ScrollView {
            VStack {
                if model.state.approval == nil && !model.state.isLoading {
                    Text("Decision sent: \(probe.receivedDecision)").accessibilityIdentifier("decision-result")
                }
                TaskApprovalCard(state: model.state, onDecide: probe.decide) {
                    DeviceStream(session: probe.connection.session)
                        .background(MountProbe { probe.deviceMounts += 1 })
                }.frame(maxWidth: probe.narrow ? 375 : .infinity)
                if probe.mode == "approval-resize" {
                    Button("Resize layout") { probe.narrow.toggle() }
                }
                Text("Device mounts: \(probe.deviceMounts)").accessibilityIdentifier("device-mounts")
            }.padding(16)
        }
    }
}
private struct MountProbe: UIViewRepresentable {
    let created: @MainActor () -> Void
    func makeUIView(context: Context) -> UIView {
        // Publish outside SwiftUI's update pass.
        Task { @MainActor in created() }
        return UIView()
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
