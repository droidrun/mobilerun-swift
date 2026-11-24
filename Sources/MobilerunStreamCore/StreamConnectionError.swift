// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Why a connection attempt failed, shared with the other Mobilerun stream SDKs (client contract v1).
public enum StreamErrorReason: String, Sendable, Equatable, CaseIterable {
    /// The token provider threw, timed out, returned a blank key or targeted a rejected host.
    case credentialsUnavailable = "credentials_unavailable"
    /// The socket closed or failed before opening: wrong device, refused origin (403), 404 or network failure.
    case connectionRefused = "connection_refused"
    /// The upgrade was answered with 401: a used, expired or revoked key.
    case tokenRejected = "token_rejected"
    /// An open session dropped, including the server's session cap.
    case disconnected
    /// The server reported the device as offline or not ready. Reserved for an explicit server indication;
    /// silence, timeouts and generic upgrade statuses never produce it.
    case deviceUnavailable = "device_unavailable"
    case unknown
    case publishNotAllowed = "publish_not_allowed", publishUnsupported = "publish_unsupported"
    case permissionDenied = "permission_denied", publishBusy = "publish_busy", publishFailed = "publish_failed"
    case publishTimeout = "publish_timeout", publishCancelled = "publish_cancelled"
}

/// One failed attempt. Messages never contain endpoints, credentials or server text.
public struct StreamConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: StreamErrorReason
    public let message: String
    /// Viewer failure index (zero is possible for publishing on a healthy connection).
    public let attempt: Int
    /// For connection errors, retries stopped. For publish errors, that operation will not retry.
    public let final: Bool
    /// Present only for publish errors; final then refers to the publish operation.
    public let operation: String?
    public let mediaSessionId: String?
    public let detail: String?
    public let serverReason: String?
    public init(reason: StreamErrorReason, message: String, attempt: Int, final: Bool) {
        self.init(reason: reason, message: message, attempt: attempt, final: final, operation: nil)
    }
    public init(reason: StreamErrorReason, message: String, attempt: Int, final: Bool,
                operation: String? = nil, mediaSessionId: String? = nil,
                detail: String? = nil, serverReason: String? = nil) {
        self.reason = reason
        self.message = message
        self.attempt = attempt
        self.final = final
        self.operation = operation; self.mediaSessionId = mediaSessionId
        self.detail = detail; self.serverReason = serverReason
    }
    public var description: String { "StreamConnectionError(\(reason.rawValue), attempt \(attempt), final \(final))" }
}

extension StreamErrorReason {
    package var defaultMessage: String {
        switch self {
        case .credentialsUnavailable: "The stream key could not be obtained."
        case .connectionRefused: "The stream connection was refused."
        case .tokenRejected: "The stream key was rejected."
        case .disconnected: "The stream disconnected."
        case .deviceUnavailable: "The device is unavailable."
        case .publishNotAllowed: "Media publication is not allowed."
        case .publishUnsupported: "Media publication is unsupported."
        case .permissionDenied: "Microphone or camera permission was denied."
        case .publishBusy: "Another media publisher is active."
        case .publishFailed: "Media publication failed."
        case .publishTimeout: "Media publication timed out."
        case .publishCancelled: "Media publication was cancelled."
        case .unknown: "The stream connection failed."
        }
    }
}
