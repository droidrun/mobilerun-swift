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
    @Published var belowBreakpoint = false
    var forcedReconnect = false
    var advanceApproval: () -> Void = {}
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--ui-state")
        mode = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "connecting"
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(mode == "approval-expired" ? -1 : 65))
        let pending = PendingApproval(approvalId: "example", kind: "payment_card", details: [
            "label": .string("Visa 4242"), "targetPackage": .string(mode == "approval-long" ? String(repeating: "com.example.long.package.", count: 12) : "com.example.shop"),
            "targetHost": .string(mode == "approval-long" ? String(repeating: "long-domain.", count: 16) + "example.com" : "example.com")
        ], expiresAt: expiresAt)
        var finished = false
        var revision = 0
        advanceApproval = { revision += 1 }
        let fail = mode == "approval-error"
        approval = TaskApprovalModel(taskId: "example", fetchApproval: { id in
            var current = pending; current.approvalId = "\(id)-\(revision)"
            return finished ? nil : current
        }, decide: { _, _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            if fail { throw ExampleFailure.decision }
            finished = true
        })
    }
    func start() {
        if mode.hasPrefix("live") { connection.session.start() }
        else if mode.contains("unavailable") { connection.session.presentForTesting(.unavailable) }
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
    @State private var solid = false
    private var theme: StreamTheme {
        var result: StreamTheme = probe.mode.contains("dark") ? .dark : .light
        if probe.mode == "custom" {
            result.background = Color(red: 0.9, green: 0.95, blue: 1)
            result.primary = Color(red: 0.15, green: 0.25, blue: 0.5)
            result.radius = 20
        }
        result.surfaceStyle = solid || probe.mode.contains("solid") ? .solid : .glass
        return result
    }
    var body: some View {
        VStack(spacing: 8) {
            if probe.mode == "approval-glass-switch" {
                HStack {
                    Button(solid ? "Use glass" : "Use solid") { solid.toggle() }
                }
                Text(theme.surfaceStyle == .solid ? "solid" : "glass").accessibilityIdentifier("surface-style")
                SurfacePolicyProbe()
            }
            content
        }
            .environment(\.sizeCategory, probe.mode == "approval-long" ? .accessibilityExtraExtraExtraLarge : .large)
            .streamTheme(theme)
            .streamLabels(probe.mode == "custom" ? StreamLabels().with {
                $0.connecting = "Connecting your phone"; $0.back = "Go back"; $0.retry = "Try again"
            } : StreamLabels())
            .onAppear { probe.start() }
            .onDisappear { probe.approval.stop(); probe.connection.session.close() }
    }
    @ViewBuilder private var content: some View {
        if probe.mode == "reconnecting-retained" {
            VStack(spacing: 0) {
                ZStack {
                    // A bright stand-in frame makes any glass sampling/phone glyph regression visible offline.
                    LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
                    StreamPlaceholder(state: StreamOverlayState(status: .reconnecting(attempt: 3), hasVideo: true))
                }
                StreamNavigationBar()
            }
        } else if probe.mode.hasPrefix("approval") {
            ApprovalExample(probe: probe, model: probe.approval)
        } else {
            DeviceStream(session: probe.connection.session, hasControl: probe.mode != "display-only")
                .onReceive(probe.connection.session.$status) { probe.connection.mark("status \($0)") }
                .onReceive(probe.connection.session.$videoSize) { size in
                    if size != nil {
                        probe.connection.mark("frame received")
                        if probe.mode == "live-reconnecting", !probe.forcedReconnect {
                            probe.forcedReconnect = true
                            probe.connection.session.presentForTesting(.reconnecting(attempt: 3))
                        }
                    }
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
                    .frame(width: probe.mode == "approval-boundary" ? (probe.belowBreakpoint ? 767 : 768) : nil)
                if probe.mode == "approval-resize" {
                    Button("Resize layout") { probe.narrow.toggle() }
                }
                if probe.mode == "approval-boundary" {
                    Button("Toggle breakpoint") { probe.belowBreakpoint.toggle() }
                }
                if probe.mode == "approval-long" {
                    Button("Next approval") { probe.advanceApproval(); model.refetch() }
                }
                Text("Device mounts: \(probe.deviceMounts)").accessibilityIdentifier("device-mounts")
            }.padding(16)
        }
    }
}
private struct SurfacePolicyProbe: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let supported: Bool
        if #available(iOS 26, *) { supported = true } else { supported = false }
        let glass = StreamSurface.usesGlass(style: theme.surfaceStyle, supported: supported,
                                           reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        return Text(glass ? "Effective surface: glass" : "Effective surface: solid")
            .accessibilityIdentifier("effective-surface")
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
