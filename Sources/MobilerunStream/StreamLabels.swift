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
    /// Shown while reconnecting after an open session dropped.
    public var disconnected: String
    public var unavailable: String
    public var retry: String
    public var back: String
    public var home: String
    public var recent: String
    public var microphone: String
    public var camera: String
    public var stopMicrophone: String
    public var stopCamera: String
    public var publishStarting: String
    public var publishPermissionDenied: String
    public var publishNotAllowed: String
    public var publishFailed: String
    public init(connecting: String = "connecting", reconnecting: String = "reconnecting",
                reconnectingAttempt: String = "reconnecting ({attempt}/{max})", disconnected: String = "disconnected",
                unavailable: String = "device stream unavailable", retry: String = "Retry",
                back: String = "Back", home: String = "Home", recent: String = "Recent") {
        self.init(connecting: connecting, reconnecting: reconnecting, reconnectingAttempt: reconnectingAttempt,
                  disconnected: disconnected, unavailable: unavailable, retry: retry,
                  back: back, home: home, recent: recent, microphone: "Microphone")
    }
    public init(connecting: String = "connecting", reconnecting: String = "reconnecting",
                reconnectingAttempt: String = "reconnecting ({attempt}/{max})",
                disconnected: String = "disconnected",
                unavailable: String = "device stream unavailable", retry: String = "Retry",
                back: String = "Back", home: String = "Home", recent: String = "Recent",
                microphone: String = "Microphone", camera: String = "Camera",
                stopMicrophone: String = "Stop microphone", stopCamera: String = "Stop camera",
                publishStarting: String = "Starting media",
                publishPermissionDenied: String = "Allow microphone and camera access in Settings.",
                publishNotAllowed: String = "Media publication is not allowed.",
                publishFailed: String = "Media publication could not start.") {
        self.connecting = connecting; self.reconnecting = reconnecting
        self.reconnectingAttempt = reconnectingAttempt; self.disconnected = disconnected
        self.unavailable = unavailable
        self.microphone = microphone; self.camera = camera
        self.stopMicrophone = stopMicrophone; self.stopCamera = stopCamera
        self.publishStarting = publishStarting; self.publishPermissionDenied = publishPermissionDenied
        self.publishNotAllowed = publishNotAllowed; self.publishFailed = publishFailed
        self.retry = retry; self.back = back; self.home = home; self.recent = recent
    }
    package func publishLabel(_ state: PublishState) -> String? {
        switch state.phase {
        case .capturing, .starting, .accepted: return publishStarting
        case .error:
            switch state.reason {
            case "permission_denied": return publishPermissionDenied
            case "publish_not_allowed": return publishNotAllowed
            default: return publishFailed
            }
        default: return nil
        }
    }
    func statusLabel(_ status: StreamStatus, error: StreamConnectionError? = nil) -> String {
        switch status {
        case .reconnecting(let attempt):
            if attempt <= 1, error?.reason == .disconnected { return disconnected }
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
