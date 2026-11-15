// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import MobilerunStreamCore

/// Value types with defaulted fields support independent overrides.
public protocol StreamCustomizable {}
public extension StreamCustomizable {
    func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

/// English stream/navigation labels, including accessibility names.
public struct StreamLabels: Sendable, Equatable, StreamCustomizable {
    public var connecting: String
    public var reconnecting: String
    public var reconnectingAttempt: String
    public var unavailable: String
    public var retry: String
    public var back: String
    public var home: String
    public var recent: String
    public init(connecting: String = "connecting", reconnecting: String = "reconnecting",
                reconnectingAttempt: String = "reconnecting ({attempt}/{max})",
                unavailable: String = "device stream unavailable", retry: String = "Retry",
                back: String = "Back", home: String = "Home", recent: String = "Recent") {
        self.connecting = connecting; self.reconnecting = reconnecting
        self.reconnectingAttempt = reconnectingAttempt; self.unavailable = unavailable
        self.retry = retry; self.back = back; self.home = home; self.recent = recent
    }
    public func statusLabel(_ status: StreamStatus) -> String {
        switch status {
        case .reconnecting(let attempt):
            return attempt > 1 ? reconnectingAttempt
                .replacingOccurrences(of: "{attempt}", with: String(attempt))
                .replacingOccurrences(of: "{max}", with: String(ReconnectPolicy.maxAttempts)) : reconnecting
        default: return connecting
        }
    }
}

/// English approval labels, independently overridable from stream chrome.
public struct TaskApprovalLabels: Sendable, Equatable, StreamCustomizable {
    public var paymentCardTitle: String
    public var waiting: String
    public var card: String
    public var app: String
    public var domain: String
    public var timeLeft: String
    public var expired: String
    public var approve: String
    public var deny: String
    public var viewSwitch: String
    public var details: String
    public var device: String
    public init(
        paymentCardTitle: String = "Approve payment",
        waiting: String = "Waiting for approval",
        card: String = "Card",
        app: String = "App",
        domain: String = "Domain",
        timeLeft: String = "{time} left",
        expired: String = "Approval expired",
        approve: String = "Approve",
        deny: String = "Deny",
        viewSwitch: String = "Approval view",
        details: String = "Details",
        device: String = "Device"
    ) {
        self.paymentCardTitle = paymentCardTitle
        self.waiting = waiting
        self.card = card
        self.app = app
        self.domain = domain
        self.timeLeft = timeLeft
        self.expired = expired
        self.approve = approve
        self.deny = deny
        self.viewSwitch = viewSwitch
        self.details = details
        self.device = device
    }
}

#if os(iOS)
import SwiftUI
private struct StreamLabelsKey: EnvironmentKey { static let defaultValue = StreamLabels() }
private struct TaskApprovalLabelsKey: EnvironmentKey { static let defaultValue = TaskApprovalLabels() }
public extension EnvironmentValues {
    var streamLabels: StreamLabels {
        get { self[StreamLabelsKey.self] } set { self[StreamLabelsKey.self] = newValue }
    }
    var taskApprovalLabels: TaskApprovalLabels {
        get { self[TaskApprovalLabelsKey.self] } set { self[TaskApprovalLabelsKey.self] = newValue }
    }
}
public extension View {
    func streamLabels(_ labels: StreamLabels) -> some View { environment(\.streamLabels, labels) }
    func taskApprovalLabels(_ labels: TaskApprovalLabels) -> some View { environment(\.taskApprovalLabels, labels) }
}
#endif
