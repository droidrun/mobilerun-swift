// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit
import MobilerunProtocol

@MainActor public struct TaskApprovalActionsState {
    public var isPending: Bool
    public var decision: ApprovalDecision?
    public var onDecide: (ApprovalDecision) -> Void
    public init(isPending: Bool = false, decision: ApprovalDecision? = nil,
                onDecide: @escaping (ApprovalDecision) -> Void) {
        self.isPending = isPending; self.decision = decision; self.onDecide = onDecide
    }
}

private enum TaskApprovalLayout {
    static let padding: CGFloat = 16
    static let breakpoint: CGFloat = 768
    static let wideHeight: CGFloat = 428
    static let narrowHeight: CGFloat = 320
    static let deviceWidth: CGFloat = 256
    static let deviceHeight: CGFloat = 320
    static let columnGap: CGFloat = 24
}

/// Backend-owned approval, including unknown kinds. Countdown never disables the actions.
/// The device stays in one structural position across switch/width changes.
@MainActor public struct TaskApprovalCard<Device: View>: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.taskApprovalLabels) private var labels
    @State private var showDevice = false
    @State private var selectedApprovalId: String?
    @State private var cardWidth: CGFloat = 0
    @State private var errorAnnouncement = ApprovalErrorAnnouncement()
    private let state: TaskApprovalState
    private let onDecide: (ApprovalDecision) -> Void
    private let device: Device
    private let hasDevice: Bool
    private let actions: (TaskApprovalActionsState) -> AnyView
    public init(state: TaskApprovalState, onDecide: @escaping (ApprovalDecision) -> Void,
                actions: @escaping (TaskApprovalActionsState) -> AnyView = { AnyView(StreamApprovalActions(state: $0)) },
                @ViewBuilder device: () -> Device) {
        self.state = state; self.onDecide = onDecide; self.actions = actions
        self.device = device(); hasDevice = Device.self != EmptyView.self
    }
    public var body: some View {
        if let approval = state.approval {
            let wide = cardWidth >= TaskApprovalLayout.breakpoint
            let showingDevice = showDevice && selectedApprovalId == approval.approvalId
            let viewportHeight = wide ? TaskApprovalLayout.wideHeight : TaskApprovalLayout.narrowHeight
            VStack(alignment: .leading, spacing: 16) {
                Text(approval.paymentCardDetails() == nil ? labels.waiting : labels.paymentCardTitle).fontWeight(.semibold)
                ApprovalCountdown(expiresAt: approval.expiresAt)
                    .id([approval.approvalId, approval.expiresAt])
                if hasDevice {
                    if !wide { viewSwitch(approvalId: approval.approvalId, showingDevice: showingDevice) }
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            ScrollView { details(approval) }
                                .accessibilityIdentifier("approval-details")
                                .frame(width: wide ? max(0, geometry.size.width - TaskApprovalLayout.deviceWidth - TaskApprovalLayout.columnGap) : geometry.size.width,
                                       height: viewportHeight, alignment: .topLeading)
                                .opacity(wide || !showingDevice ? 1 : 0)
                                .allowsHitTesting(wide || !showingDevice).accessibilityHidden(!wide && showingDevice)
                            device.frame(width: wide ? TaskApprovalLayout.deviceWidth : geometry.size.width,
                                         height: wide ? TaskApprovalLayout.wideHeight : TaskApprovalLayout.deviceHeight)
                                .clipped().offset(x: wide ? max(0, geometry.size.width - TaskApprovalLayout.deviceWidth) : 0)
                                .opacity(wide || showingDevice ? 1 : 0)
                                .allowsHitTesting(wide || showingDevice).accessibilityHidden(!wide && !showingDevice)
                        }
                    }.frame(height: viewportHeight)
                } else {
                    details(approval)
                }
                decisionContent
            }
            .font(theme.typography).foregroundColor(theme.cardForeground).padding(TaskApprovalLayout.padding)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { cardWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { cardWidth = $0 }
            })
            .background(theme.card).clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius).stroke(theme.border, lineWidth: 1))
            .onAppear { announceErrorIfChanged() }
            .onChange(of: state.error) { _ in announceErrorIfChanged() }
        }
    }
    private var decisionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = state.error {
                Text(error).foregroundColor(theme.destructive).fixedSize(horizontal: false, vertical: true)
            }
            actions(TaskApprovalActionsState(isPending: state.isDeciding, decision: state.decision, onDecide: onDecide))
        }
    }
    private func viewSwitch(approvalId: String, showingDevice: Bool) -> some View {
        StreamGlassGroup {
            HStack(spacing: 8) {
                switchButton(labels.details, selected: !showingDevice) { showDevice = false }
                switchButton(labels.device, selected: showingDevice) { selectedApprovalId = approvalId; showDevice = true }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(labels.viewSwitch)
    }
    private func switchButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(maxWidth: .infinity) }
            .modifier(StreamChromeButton(kind: selected ? .primary : .outline))
            .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius).stroke(selected ? theme.ring : .clear, lineWidth: 1))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private func details(_ approval: PendingApproval) -> some View {
        if let card = approval.paymentCardDetails() {
            VStack(spacing: 0) {
                fact(labels.card, value: card.card, symbol: "creditcard")
                Divider().overlay(theme.border)
                fact(labels.app, value: card.targetPackage, symbol: "app")
                if let host = card.targetHost {
                    Divider().overlay(theme.border)
                    fact(labels.domain, value: host, symbol: "globe")
                }
            }.overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.border, lineWidth: 1))
        }
    }
    private func fact(_ label: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 36, height: 36).foregroundColor(theme.mutedForeground)
                .background(theme.muted).cornerRadius(theme.buttonRadius).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundColor(theme.mutedForeground)
                Text(value).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func announceErrorIfChanged() {
        guard errorAnnouncement.update(state.error), let message = state.error else { return }
        // Native VoiceOver announcement interrupts less urgent speech (ARIA role=alert parity).
        let text = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: false])
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
public extension TaskApprovalCard where Device == EmptyView {
    init(state: TaskApprovalState, onDecide: @escaping (ApprovalDecision) -> Void,
         actions: @escaping (TaskApprovalActionsState) -> AnyView = { AnyView(StreamApprovalActions(state: $0)) }) {
        self.init(state: state, onDecide: onDecide, actions: actions) { EmptyView() }
    }
}

@MainActor public struct StreamApprovalActions: View {
    @Environment(\.taskApprovalLabels) private var labels
    public var state: TaskApprovalActionsState
    public init(state: TaskApprovalActionsState) { self.state = state }
    public var body: some View {
        StreamGlassGroup {
            HStack(spacing: 8) {
                action(.approve, label: labels.approve, symbol: "checkmark")
                action(.deny, label: labels.deny, symbol: "xmark")
            }
        }
    }
    private func action(_ decision: ApprovalDecision, label: String, symbol: String) -> some View {
        Button { if !state.isPending { state.onDecide(decision) } } label: {
            HStack {
                if state.isPending && state.decision == decision { ProgressView() }
                else { Image(systemName: symbol) }
                Text(label)
            }.frame(maxWidth: .infinity)
        }.modifier(StreamChromeButton(kind: decision == .approve ? .primary : .outline)).disabled(state.isPending)
    }
}

/// Only this leaf ticks; expiry cancels its task. The card/device never observes the clock.
struct ApprovalCountdown: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.taskApprovalLabels) private var labels
    let expiresAt: String
    @State private(set) var remaining: Double
    init(expiresAt: String) {
        self.expiresAt = expiresAt
        _remaining = State(initialValue: remainingMs(expiresAt: expiresAt))
    }
    var body: some View {
        Label(remaining > 0 ? labels.timeLeft.replacingOccurrences(of: "{time}", with: formatRemaining(remaining)) : labels.expired,
              systemImage: "clock")
            .monospacedDigit().padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundColor(theme.mutedForeground).background(theme.muted).clipShape(Capsule())
            .accessibilityAddTraits(.updatesFrequently)
            .task {
                remaining = remainingMs(expiresAt: expiresAt)
                while remaining > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(min(1000, remaining) * 1_000_000)) } catch { return }
                    remaining = remainingMs(expiresAt: expiresAt)
                }
            }
    }
}
#endif
