// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Connection phase that determines whether malformed signalling frames fail startup or are ignored.
public enum SignallingPhase: Sendable {
    /// Waiting for the first configuration reply.
    case awaitingRTCConfiguration
    /// The peer connection and general message handler exist.
    case established
}

/// Result of parsing a server text frame.
public enum ServerFrame: Sendable, Equatable {
    /// A recognized message.
    case message(ServerMessage)
    /// Unknown, irrelevant, or malformed established-session frame.
    case ignored
    /// Invalid JSON or an unusable reply while awaiting configuration.
    case startupFailure
}

/// Typed server messages. Payloads have no public initializers; use ``parse(_:phase:)``.
public enum ServerMessage: Sendable, Equatable {
    /// SDP answer to the latest offer.
    case answer(Answer)
    /// Remote candidate; buffer until the remote description is applied.
    case candidate(Candidate)
    /// Initial configuration or a later credential refresh, according to the connection phase.
    case rtcConfiguration(RTCConfiguration)
    /// Successful screenshot reply.
    case screenshot(Screenshot)
    /// Failed screenshot reply.
    case screenshotError(ScreenshotError)

    /// Parsed SDP answer.
    public struct Answer: Sendable, Equatable {
        /// Answer SDP.
        public let sdp: String
    }

    /// Parsed remote ICE candidate.
    public struct Candidate: Sendable, Equatable {
        /// Candidate SDP line.
        public let candidate: String
        /// Media stream identifier, if provided.
        public let sdpMid: String?
        /// Media line index, if provided.
        public let sdpMLineIndex: Int?
    }

    /// Full configuration, preserving all fields for the connection layer.
    public struct RTCConfiguration: Sendable, Equatable {
        /// Configuration object, or nil if missing or null.
        public let configuration: [String: JSONValue]?

        /// Typed ICE servers, or nil if absent or malformed. An empty array is a valid refresh.
        public var iceServers: [ICEServer]? {
            guard case .array(let entries) = configuration?["iceServers"] else { return nil }
            let servers = entries.compactMap(ICEServer.init)
            return servers.count == entries.count ? servers : nil
        }
    }

    /// Parsed ICE server entry.
    public struct ICEServer: Sendable, Equatable {
        /// One or more URLs; a wire string is normalized to a one-element array.
        public let urls: [String]
        /// Optional TURN username.
        public let username: String?
        /// Optional TURN credential.
        public let credential: String?

        fileprivate init?(_ value: JSONValue) {
            guard let object = value.object else { return nil }
            if let url = object["urls"]?.string { urls = [url] }
            else if case .array(let values) = object["urls"] {
                let strings = values.compactMap(\.string)
                guard strings.count == values.count else { return nil }
                urls = strings
            } else { return nil }
            guard validOptionalString(object["username"]), validOptionalString(object["credential"]) else {
                return nil
            }
            username = object["username"]?.string
            credential = object["credential"]?.string
        }
    }

    /// Parsed successful screenshot reply.
    public struct Screenshot: Sendable, Equatable {
        /// Request correlation identifier.
        public let id: String
        /// Image encoded as a data URI.
        public let dataURI: String
    }

    /// Parsed failed screenshot reply.
    public struct ScreenshotError: Sendable, Equatable {
        /// Request correlation identifier.
        public let id: String
        /// Human-readable failure reason.
        public let message: String
    }

    /// Parses a server frame. Invalid JSON (including literal null) fails startup only while
    /// awaiting configuration. Other valid message types are ignored during that phase.
    public static func parse(_ text: String, phase: SignallingPhase) -> ServerFrame {
        let malformedFrame: ServerFrame = phase == .awaitingRTCConfiguration ? .startupFailure : .ignored
        let data = repairingJSONSurrogates(Data(text.utf8))
        let decoder = JSONDecoder()
        // Decode only the discriminator first. Foundation can scan valid JSON numbers like 1e999
        // without converting them to Double, so unrelated startup frames are still ignored.
        // Known difference: Foundation keeps the first duplicate object key; JSON.parse keeps the last.
        guard let header = try? decoder.decode(FrameHeader.self, from: data), !header.isNull else {
            return malformedFrame
        }
        guard header.isObject else { return .ignored }
        if phase == .awaitingRTCConfiguration, header.type != "rtcConfiguration" { return .ignored }
        guard let json = try? decoder.decode(JSONValue.self, from: data), let object = json.object else {
            return header.type == "rtcConfiguration" ? malformedFrame : .ignored
        }
        switch header.type {
        case "answer":
            guard let sdp = object["sdp"]?.string else { return .ignored }
            return .message(.answer(Answer(sdp: sdp)))
        case "candidate":
            guard let candidate = object["candidate"]?.string,
                  validOptionalString(object["sdpMid"]) else { return .ignored }
            let index: Int?
            if let value = object["sdpMLineIndex"], value != .null {
                guard case .number(let number) = value, let integer = Int(exactly: number) else {
                    return .ignored
                }
                index = integer
            } else { index = nil }
            return .message(.candidate(Candidate(candidate: candidate, sdpMid: object["sdpMid"]?.string,
                                                 sdpMLineIndex: index)))
        case "rtcConfiguration":
            let config = object["rtcConfiguration"]
            guard config == nil || config == .null || config?.object != nil else {
                return malformedFrame
            }
            return .message(.rtcConfiguration(RTCConfiguration(configuration: config?.object)))
        case "screenshot":
            guard let id = object["id"]?.string, let uri = object["dataUri"]?.string else { return .ignored }
            return .message(.screenshot(Screenshot(id: id, dataURI: uri)))
        case "screenshotError":
            guard let id = object["id"]?.string, let message = object["message"]?.string else {
                return .ignored
            }
            return .message(.screenshotError(ScreenshotError(id: id, message: message)))
        default: return .ignored
        }
    }

    // Re-serialize recognized fields for conformance comparisons.
    func toJSON() throws -> String {
        let object: [String: JSONValue]
        switch self {
        case .answer(let answer):
            object = ["type": .string("answer"), "sdp": .string(answer.sdp)]
        case .candidate(let candidate):
            object = ["type": .string("candidate"), "candidate": .string(candidate.candidate),
                      "sdpMid": candidate.sdpMid.map(JSONValue.string) ?? .null,
                      "sdpMLineIndex": candidate.sdpMLineIndex.map { .number(Double($0)) } ?? .null]
        case .rtcConfiguration(let config):
            var fields: [String: JSONValue] = ["type": .string("rtcConfiguration")]
            if let configuration = config.configuration {
                fields["rtcConfiguration"] = .object(configuration)
            }
            object = fields
        case .screenshot(let screenshot):
            object = ["type": .string("screenshot"), "id": .string(screenshot.id),
                      "dataUri": .string(screenshot.dataURI)]
        case .screenshotError(let error):
            object = ["type": .string("screenshotError"), "id": .string(error.id),
                      "message": .string(error.message)]
        }
        return try jsonText(object)
    }
}

private func validOptionalString(_ value: JSONValue?) -> Bool {
    value == nil || value == .null || value?.string != nil
}

// A discriminator-only decode avoids converting irrelevant numeric fields during startup.
private struct FrameHeader: Decodable {
    let isNull: Bool
    let isObject: Bool
    let type: String?

    private enum Keys: String, CodingKey { case type }

    init(from decoder: any Decoder) throws {
        isNull = try decoder.singleValueContainer().decodeNil()
        let object = try? decoder.container(keyedBy: Keys.self)
        isObject = object != nil
        type = try? object?.decode(String.self, forKey: .type)
    }
}
