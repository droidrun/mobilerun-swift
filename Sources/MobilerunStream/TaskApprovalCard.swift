// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit
import MobilerunProtocol

@MainActor public struct TaskApprovalActionsState {
    public var isDeciding: Bool
    public var decision: ApprovalDecision?
    public var onDecide: (ApprovalDecision) -> Void
    public init(isDeciding: Bool = false, decision: ApprovalDecision? = nil,
                onDecide: @escaping (ApprovalDecision) -> Void = { _ in }) {
        self.isDeciding = isDeciding; self.decision = decision; self.onDecide = onDecide
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

/// Backend-owned approval, including unknown kinds. Countdown never disables the actions.
/// The device stays in one structural position across switch/width changes.
@MainActor public struct TaskApprovalCard<Device: View>: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    @State private var showDevice = false
    private let state: TaskApprovalState
    private let onDecide: (ApprovalDecision) -> Void
    private let device: Device
    private let hasDevice: Bool
    private let actions: (TaskApprovalActionsState) -> AnyView
    public init(state: TaskApprovalState = TaskApprovalState(), onDecide: @escaping (ApprovalDecision) -> Void,
                actions: @escaping (TaskApprovalActionsState) -> AnyView = { AnyView(StreamApprovalActions(state: $0)) },
                @ViewBuilder device: () -> Device) {
        self.state = state; self.onDecide = onDecide; self.actions = actions
        self.device = device(); hasDevice = Device.self != EmptyView.self
    }
    public var body: some View {
        if let approval = state.approval {
            VStack(alignment: .leading, spacing: 16) {
                Text(cardDetails(approval) == nil ? labels.waiting : labels.paymentCardTitle).fontWeight(.semibold)
                ApprovalCountdown(expiresAt: approval.expiresAt)
                if hasDevice {
                    GeometryReader { geometry in
                        let wide = geometry.size.width >= 768
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 16) {
                                details(approval)
                                    .opacity(wide || !showDevice ? 1 : 0)
                                    .allowsHitTesting(wide || !showDevice).accessibilityHidden(!wide && showDevice)
                                Spacer(minLength: 0)
                                decisionContent
                            }
                            .frame(width: wide ? max(0, geometry.size.width - 280) : geometry.size.width,
                                   height: wide ? 428 : 380, alignment: .topLeading)
                            device.frame(width: wide ? 256 : geometry.size.width, height: wide ? 428 : 320)
                                .clipped().offset(x: wide ? max(0, geometry.size.width - 256) : 0)
                                .opacity(wide || showDevice ? 1 : 0)
                                .allowsHitTesting(wide || showDevice).accessibilityHidden(!wide && !showDevice)
                        }
                        .padding(.top, wide ? 0 : 48)
                        .overlay(alignment: .top) {
                            if !wide { viewSwitch }
                        }
                    }.frame(height: 428)
                } else {
                    details(approval)
                    decisionContent
                }
            }
            .font(theme.typography).foregroundColor(theme.cardForeground).padding(16)
            .background(theme.card).clipShape(RoundedRectangle(cornerRadius: theme.radius))
            .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.border, lineWidth: 1))
            .onChange(of: approval.approvalId) { _ in showDevice = false }
        }
    }
    private var decisionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = state.error {
                Text(error.localizedDescription).foregroundColor(theme.destructive)
                    .onAppear { announce(error.localizedDescription) }
                    .onChange(of: error.localizedDescription) { announce($0) }
            }
            actions(TaskApprovalActionsState(isDeciding: state.isDeciding, decision: state.decision, onDecide: onDecide))
        }
    }
    private var viewSwitch: some View {
        HStack(spacing: 8) {
            switchButton(labels.details, selected: !showDevice) { showDevice = false }
            switchButton(labels.device, selected: showDevice) { showDevice = true }
        }.accessibilityElement(children: .contain).accessibilityLabel(labels.viewSwitch)
    }
    private func switchButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(maxWidth: .infinity) }
            .buttonStyle(StreamButtonStyle(outline: !selected))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? theme.ring : .clear, lineWidth: 1))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func cardDetails(_ approval: PendingApproval) -> PaymentCardDetails? {
        approval.kind == "payment_card" ? parsePaymentCardDetails(.object(approval.details)) : nil
    }
    @ViewBuilder private func details(_ approval: PendingApproval) -> some View {
        if let card = cardDetails(approval) {
            VStack(spacing: 0) {
                fact(labels.card, value: card.card, symbol: "creditcard")
                Divider().overlay(theme.border)
                fact(labels.app, value: card.targetPackage, symbol: "app")
                if let host = card.targetHost {
                    Divider().overlay(theme.border)
                    fact(labels.domain, value: host, symbol: "globe")
                }
            }.overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        }
    }
    private func fact(_ label: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 36, height: 36).foregroundColor(theme.mutedForeground)
                .background(theme.muted).cornerRadius(6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundColor(theme.mutedForeground)
                Text(value).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func announce(_ message: String) {
        // Native VoiceOver announcement interrupts less urgent speech (ARIA role=alert parity).
        let text = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: false])
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
public extension TaskApprovalCard where Device == EmptyView {
    init(state: TaskApprovalState = TaskApprovalState(), onDecide: @escaping (ApprovalDecision) -> Void,
         actions: @escaping (TaskApprovalActionsState) -> AnyView = { AnyView(StreamApprovalActions(state: $0)) }) {
        self.init(state: state, onDecide: onDecide, actions: actions) { EmptyView() }
    }
}

@MainActor public struct StreamApprovalActions: View {
    @Environment(\.streamLabels) private var labels
    public var state: TaskApprovalActionsState
    public init(state: TaskApprovalActionsState = TaskApprovalActionsState()) { self.state = state }
    public var body: some View {
        HStack(spacing: 8) {
            action(.approve, label: labels.approve, symbol: "checkmark")
            action(.deny, label: labels.deny, symbol: "xmark")
        }
    }
    private func action(_ decision: ApprovalDecision, label: String, symbol: String) -> some View {
        Button { if !state.isDeciding { state.onDecide(decision) } } label: {
            HStack {
                if state.isDeciding && state.decision == decision { ProgressView() }
                else { Image(systemName: symbol) }
                Text(label)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(StreamButtonStyle(outline: decision == .deny)).disabled(state.isDeciding)
    }
}

/// Only this leaf ticks; expiry cancels its task. The card/device never observes the clock.
private struct ApprovalCountdown: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    let expiresAt: String
    @State private var now = Date().timeIntervalSince1970 * 1000
    var body: some View {
        let remaining = remainingMs(expiresAt: expiresAt, nowMs: now)
        Label(remaining > 0 ? labels.timeLeft.replacingOccurrences(of: "{time}", with: formatRemaining(remaining)) : labels.expired,
              systemImage: "clock")
            .monospacedDigit().padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundColor(theme.mutedForeground).background(theme.muted).clipShape(Capsule())
            .accessibilityAddTraits(.updatesFrequently)
            .task(id: expiresAt) {
                now = Date().timeIntervalSince1970 * 1000
                while remainingMs(expiresAt: expiresAt, nowMs: now) > 0 {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    now = Date().timeIntervalSince1970 * 1000
                }
            }
    }
}
#endif
