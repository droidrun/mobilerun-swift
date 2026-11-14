// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An outgoing signalling message. Candidate null fields are always written explicitly.
public enum ClientMessage: Sendable, Equatable {
    /// Requests ICE configuration and always opts into live credential refresh.
    case requestRTCConfiguration(sessionID: String)
    /// Initial or ICE-restart SDP offer.
    case offer(sdp: String, sessionID: String)
    /// Locally gathered candidate; the null end-of-candidates event is not sent.
    case candidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?, sessionID: String)
    /// Periodic keep-alive while visible and the socket is open.
    case keepAlive(sessionID: String)
    /// Requests a fresh encoded frame after the control channel opens.
    case requestFrame(sessionID: String)
    /// Opens a URL built by ``OpenURL/create(suppliedURL:sessionID:)``.
    case openURL(OpenURL)
    /// Screenshot request, correlated by ID; has no session ID.
    case screenshot(id: String)

    /// A URL message created only through its percent-decoding factory.
    public struct OpenURL: Sendable, Equatable {
        /// Decoded URL to open on the device.
        public let url: String
        /// Stream session identifier.
        public let sessionID: String

        private init(url: String, sessionID: String) {
            self.url = url
            self.sessionID = sessionID
        }

        /// Applies ECMAScript decodeURIComponent: `+` stays literal and invalid escapes or UTF-8
        /// leave the entire supplied string unchanged.
        public static func create(suppliedURL: String, sessionID: String) -> Self {
            Self(url: suppliedURL.removingPercentEncoding ?? suppliedURL, sessionID: sessionID)
        }
    }

    /// Serializes the typed message to a JSON text frame.
    public func toJSON() throws -> String {
        try jsonText(object)
    }

    private var object: [String: JSONValue] {
        var object: [String: JSONValue]
        switch self {
        case .requestRTCConfiguration(let sessionID):
            object = sessionObject(type: "requestRtcConfiguration", sessionID: sessionID)
            object["supportsLiveRtcRefresh"] = .bool(true)
        case .offer(let sdp, let sessionID):
            object = sessionObject(type: "offer", sessionID: sessionID)
            object["sdp"] = .string(sdp)
        case .candidate(let candidate, let sdpMid, let index, let sessionID):
            object = sessionObject(type: "candidate", sessionID: sessionID)
            object["candidate"] = .string(candidate)
            object["sdpMid"] = sdpMid.map(JSONValue.string) ?? .null
            object["sdpMLineIndex"] = index.map { .number(Double($0)) } ?? .null
        case .keepAlive(let sessionID):
            object = sessionObject(type: "keepAlive", sessionID: sessionID)
        case .requestFrame(let sessionID):
            object = sessionObject(type: "requestFrame", sessionID: sessionID)
        case .openURL(let message):
            object = sessionObject(type: "openUrl", sessionID: message.sessionID)
            object["url"] = .string(message.url)
        case .screenshot(let id):
            object = ["type": .string("screenshot"), "id": .string(id)]
        }
        return object
    }
}

private func sessionObject(type: String, sessionID: String) -> [String: JSONValue] {
    ["type": .string(type), "sessionId": .string(sessionID)]
}
