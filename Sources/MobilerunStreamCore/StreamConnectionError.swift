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
}

/// One failed attempt. Messages never contain endpoints, credentials or server text.
public struct StreamConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: StreamErrorReason
    public let message: String
    /// One-based count of consecutive failures.
    public let attempt: Int
    /// True when the SDK stopped retrying; the host's retry control starts a fresh cycle.
    public let final: Bool
    public init(reason: StreamErrorReason, message: String, attempt: Int, final: Bool) {
        self.reason = reason
        self.message = message
        self.attempt = attempt
        self.final = final
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
        case .unknown: "The stream connection failed."
        }
    }
}
