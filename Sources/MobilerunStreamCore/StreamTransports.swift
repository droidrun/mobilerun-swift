// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// Supplies a fresh, single-use key before every new signalling socket.
public typealias StreamTokenProvider = @Sendable () async throws -> String

/// A discovered stream target. Descriptions and mirrors redact its credentials.
/// Prefer tokenProvider (recommended): it supplies a fresh key per connect attempt, as single-use keys require.
/// The static token is legacy and deprecated until its hard cut: every reconnect reuses it, so a
/// single-use key fails after the first connect. The SDK logs one warning per session that uses it.
public struct StreamCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    /// Deprecated legacy static token, reused on every reconnect. Nil or empty leaves the URL unchanged when no provider is supplied.
    public let token: String?
    /// Takes precedence over static and embedded tokens; failure never falls back.
    public let tokenProvider: StreamTokenProvider?
    /// Retains the original initializer, including references to init(url:token:).
    public init(url: URL, token: String? = nil) {
        self.init(url: url, token: token, tokenProvider: nil)
    }
    public init(url: URL, token: String? = nil, tokenProvider: StreamTokenProvider? = nil) {
        self.url = url
        self.token = token
        self.tokenProvider = tokenProvider
    }
    public var description: String { "StreamCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

/// Called at start, on recovery, and after rejected tokens. Nil means the device is not ready yet.
public typealias StreamCredentialsProvider = @Sendable () async throws -> StreamCredentials?

/// State presented by a stream session. Closing a session stops status updates.
public enum StreamStatus: Sendable, Equatable {
    case connecting, connected
    case reconnecting(attempt: Int)
    case unavailable
}

/// Decoded frame dimensions before rotation; rotation is clockwise in degrees.
public struct VideoSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rotation: Int
    package init(width: Int, height: Int, rotation: Int = 0) {
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}

/// Errors intentionally contain no endpoint, credential, SDP, or server text.
public enum StreamError: LocalizedError, Sendable, Equatable {
    case notConnected, disconnected, screenshotTimeout, screenshotFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Stream is not connected."
        case .disconnected: "Stream disconnected."
        case .screenshotTimeout: "Screenshot timed out."
        case .screenshotFailed: "Screenshot failed."
        }
    }
}

package enum SignallingEvent: Sendable {
    case opened
    case message(String)
    case closed
    case failed(httpStatus: Int?)
}

/// One attempt's socket. All calls and callbacks run on the main actor; close stops callbacks.
@MainActor package protocol SignallingTransport: AnyObject, Sendable {
    var onEvent: (@MainActor (SignallingEvent) -> Void)? { get set }
    func open(_ credentials: StreamCredentials) throws
    @discardableResult func send(_ text: String) -> Bool
    func close()
}

package enum PeerConnectionState: Sendable { case new, connecting, connected, disconnected, failed, closed }
package enum PeerEvent: Sendable {
    case state(PeerConnectionState)
    case candidate(sdp: String, mid: String?, index: Int?)
    case channel(id: Int, open: Bool)
}

/// One recvonly audio/video peer, with the supplied negotiated channels. No WebRTC types cross this boundary.
@MainActor package protocol PeerTransport: AnyObject, Sendable {
    var onEvent: (@MainActor (PeerEvent) -> Void)? { get set }
    func configure(_ configuration: ServerMessage.RTCConfiguration, channels: [DataChannelSpec]) throws
    /// Creates an offer and sets it as the local description before returning.
    func createOffer(iceRestart: Bool) async throws -> String
    func setRemoteAnswer(_ sdp: String) async throws
    func addRemoteCandidate(_ candidate: ServerMessage.Candidate) async throws
    /// Refresh replaces only ICE servers, preserving the connection's other configuration.
    func setIceServers(_ servers: [ServerMessage.ICEServer]) -> Bool
    @discardableResult func send(_ data: Data, channelID: Int) -> Bool
    func close()
}
