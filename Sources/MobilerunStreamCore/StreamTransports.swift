// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// Endpoint and short-lived stream token. Obtain fresh values from your API when asked.
public struct StreamCredentials: Sendable {
    public let url: URL
    public let token: String?
    public init(url: URL, token: String? = nil) {
        self.url = url
        self.token = token
    }
}

/// Called at start, on recovery, and after rejected tokens. Nil means the device is not ready yet.
public typealias StreamCredentialsProvider = @Sendable () async throws -> StreamCredentials?

/// State presented by a stream session. Closed is permanent.
public enum StreamStatus: Sendable, Equatable {
    case connecting, connected
    case reconnecting(attempt: Int)
    case unavailable, closed
}

/// Decoded frame dimensions before rotation; rotation is clockwise in degrees.
public struct VideoSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rotation: Int
    public init(width: Int, height: Int, rotation: Int = 0) {
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}

/// Errors intentionally contain no endpoint, credential, SDP, or server text.
public enum StreamError: Error, Sendable, Equatable {
    case notConnected, disconnected, screenshotTimeout, screenshotFailed
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
