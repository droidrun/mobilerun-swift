// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inputs sent to the remote device. Audio is required; video defaults to false.
public struct PublishOptions: Sendable, Equatable {
    public let audio: Bool
    public let video: Bool
    public init(audio: Bool, video: Bool = false) { self.audio = audio; self.video = video }
    package var kinds: [PublishKind] { video ? [.audio, .video] : [.audio] }
}
public enum PublishKind: String, Sendable, Equatable { case audio, video }
public enum PublishPhase: String, Sendable, Equatable {
    case idle, capturing, starting, accepted, active, stopped, error
}
public enum PublishFailureReason: String, Sendable, Equatable {
    case publishNotAllowed = "publish_not_allowed", publishUnsupported = "publish_unsupported"
    case permissionDenied = "permission_denied", publishBusy = "publish_busy", publishFailed = "publish_failed"
    case publishTimeout = "publish_timeout", publishCancelled = "publish_cancelled", disconnected
}
extension PublishFailureReason {
    package var defaultMessage: String {
        switch self {
        case .publishNotAllowed: "Publishing is not allowed"
        case .publishUnsupported: "Inputs are not supported on this device"
        case .permissionDenied: "Microphone or camera permission denied"
        case .publishBusy: "Inputs are already in use"
        case .publishFailed: "Could not publish inputs"
        case .publishTimeout: "Publishing inputs timed out"
        case .publishCancelled: "Publishing inputs was cancelled"
        case .disconnected: "Device stream disconnected"
        }
    }
}
/// A typed start failure. Branch on reason and detail, rather than the display message.
public struct PublishFailure: LocalizedError, Sendable, Equatable {
    public let reason: PublishFailureReason
    public let message: String
    public let detail: String?
    public let serverReason: String?
    public init(reason: PublishFailureReason, message: String? = nil,
                detail: String? = nil, serverReason: String? = nil) {
        self.reason = reason; self.message = message ?? reason.defaultMessage; self.detail = detail; self.serverReason = serverReason
    }
    public var errorDescription: String? { message }
}
/// Immutable snapshot, independent of viewer connection status.
public struct PublishState: Sendable, Equatable {
    public let phase: PublishPhase
    public let mediaSessionId: String?
    public let kinds: [PublishKind]
    /// A PublishFailureReason raw value, or stopped_by_client.
    public let reason: String?
    public let message: String?
    public let detail: String?
    public let serverReason: String?
    package init(phase: PublishPhase = .idle, mediaSessionId: String? = nil, kinds: [PublishKind] = [],
                 reason: String? = nil, message: String? = nil, detail: String? = nil, serverReason: String? = nil) {
        self.phase = phase; self.mediaSessionId = mediaSessionId; self.kinds = kinds
        self.reason = reason; self.message = message; self.detail = detail; self.serverReason = serverReason
    }
}
/// Device capability snapshot supplied by the integrator's backend. This does not grant permission.
public struct DevicePublishCapabilities: Sendable, Equatable {
    public let microphoneInjection: Bool
    public let cameraInjection: Bool
    public let mediaInjectionTransport: String?
    public init(microphoneInjection: Bool, cameraInjection: Bool, mediaInjectionTransport: String? = nil) {
        self.microphoneInjection = microphoneInjection; self.cameraInjection = cameraInjection
        self.mediaInjectionTransport = mediaInjectionTransport
    }
    package var supportsMicrophone: Bool { microphoneInjection && mediaInjectionTransport == "direct" }
}

/// SDK-owned capture. Sender mutations are synchronous and serialized on the main actor, including teardown.
@MainActor package protocol PublishCapture: AnyObject {
    var onEnded: (@MainActor () -> Void)? { get set }
    func start() async throws
    func attach(_ kind: PublishKind) throws
    func stop()
    func waitForStop() async
}

extension PublishCapture {
    package func waitForStop() async {}
}
@MainActor package protocol PublishMediaTransport: AnyObject {
    var supportsPublishCamera: Bool { get }
    var supportsPublishReservations: Bool { get }
    func makePublishCapture(_ options: PublishOptions) throws -> any PublishCapture
}

/// Default UI visibility derives only from device support and the explicit hide option.
package struct PublishPresentation {
    package let visible: Bool
    package let cameraVisible: Bool
    package let starting: Bool
    package init(capabilities: DevicePublishCapabilities?, cameraSupported: Bool, shown: Bool, phase: PublishPhase, reason: String? = nil) {
        visible = shown && capabilities?.supportsMicrophone == true && reason != "publish_unsupported"
        cameraVisible = visible && capabilities?.cameraInjection == true && cameraSupported
        starting = [.capturing, .starting, .accepted].contains(phase)
    }
}
