// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import MobilerunProtocol
import Testing

@Test("Server signalling objects", arguments: try signallingCases(prefix: "server-"))
func serverMessage(_ item: SignallingCase) throws {
    let input = String(decoding: try JSONEncoder().encode(item.json), as: UTF8.self)
    guard case .message(let message) = ServerMessage.parse(input, phase: .established) else {
        Issue.record("Expected parsed server message: \(item.testDescription)")
        return
    }
    #expect(try jsonObject(message.toJSON()) == item.json)
}

@Test("Client signalling objects", arguments: try signallingCases(prefix: "client-"))
func clientMessage(_ item: SignallingCase) throws {
    let object = item.json
    let message: ClientMessage
    func session() throws -> String { try #require(object["sessionId"]?.stringValue) }
    switch object["type"]?.stringValue {
    case "requestRtcConfiguration": message = try .requestRTCConfiguration(sessionID: session())
    case "offer": message = try .offer(sdp: #require(object["sdp"]?.stringValue), sessionID: session())
    case "candidate":
        message = try .candidate(
            candidate: #require(object["candidate"]?.stringValue),
            sdpMid: object["sdpMid"]?.stringValue,
            sdpMLineIndex: object["sdpMLineIndex"]?.intValue, sessionID: session())
    case "keepAlive": message = try .keepAlive(sessionID: session())
    case "requestFrame": message = try .requestFrame(sessionID: session())
    case "openUrl":
        let url = try #require(object["url"]?.stringValue)
        let encoded = try #require(url.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        message = try .openURL(.create(suppliedURL: encoded, sessionID: session()))
    case "screenshot": message = try .screenshot(id: #require(object["id"]?.stringValue))
    default: Issue.record("Unhandled client fixture \(item.file)"); return
    }
    #expect(try jsonObject(message.toJSON()) == object)
}

@Test("Malformed JSON follows the connection phase", arguments: ["not json", "", "{\"type\":", "null"])
func malformedFrames(_ text: String) {
    #expect(ServerMessage.parse(text, phase: .awaitingRTCConfiguration) == .startupFailure)
    #expect(ServerMessage.parse(text, phase: .established) == .ignored)
}

@Test("Startup ignores valid frames of other types", arguments: [
    "42", "[]", "true", "{}", #"{"type":7}"#, #"{"type":"future"}"#,
    #"{"type":"answer","sdp":"x"}"#, #"{"type":"future","extra":"\ud800"}"#,
    #"{"type":"future","extra":1e999}"#, #"{"type":"answer","sdp":1e999}"#,
    #"{"type":1e999}"#, "1e999", "[1e999]",
])
func ignoredStartupFrames(_ text: String) {
    #expect(ServerMessage.parse(text, phase: .awaitingRTCConfiguration) == .ignored)
}

@Test("Established sessions ignore unknown or unusable frames", arguments: [
    #"{"type":"answer"}"#, #"{"type":"screenshot","id":1,"dataUri":"x"}"#,
    #"{"type":"screenshotError","id":"a"}"#, #"{"type":"future"}"#,
    #"{"type":"candidate","candidate":"x","sdpMLineIndex":0.5}"#,
    #"{"type":"future","extra":1e999}"#,
])
func ignoredEstablishedFrames(_ text: String) {
    #expect(ServerMessage.parse(text, phase: .established) == .ignored)
}

@Test("Unusable configuration follows the connection phase", arguments: [
    #"{"type":"rtcConfiguration","rtcConfiguration":"bad"}"#,
    #"{"type":"rtcConfiguration","rtcConfiguration":{"extra":1e999}}"#,
])
func unusableConfiguration(_ text: String) {
    #expect(ServerMessage.parse(text, phase: .awaitingRTCConfiguration) == .startupFailure)
    #expect(ServerMessage.parse(text, phase: .established) == .ignored)
}

@Test("Unknown fields are omitted from known messages")
func unknownFields() throws {
    let text = #"{"type":"answer","sdp":"x","extra":1}"#
    guard case .message(let message) = ServerMessage.parse(text, phase: .established) else {
        Issue.record("Expected answer"); return
    }
    #expect(try jsonObject(message.toJSON()) == ["type": .string("answer"), "sdp": .string("x")])
}

@Test("Lone surrogate server strings parse with UTF-16 repair", arguments: [
    (#"{"type":"answer","sdp":"\ud800"}"#, "�"),
    (#"{"type":"answer","sdp":"a\udc00b"}"#, "a�b"),
    (#"{"type":"answer","sdp":"\ud83d\ude00"}"#, "😀"),
    (#"{"type":"answer","sdp":"\\ud800"}"#, #"\ud800"#),
    (#"{"type":"answer","sdp":"\ud800\u0022\u005c"}"#, "�\"\\"),
])
func serverSurrogates(text: String, expected: String) {
    guard case .message(.answer(let answer)) = ServerMessage.parse(text, phase: .established) else {
        Issue.record("Expected repaired answer"); return
    }
    #expect(answer.sdp == expected)
}

@Test("Surrogate escapes do not invalidate startup configuration")
func startupSurrogates() {
    let text = #"{"type":"rtcConfiguration","rtcConfiguration":{"label":"\ud800"}}"#
    guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(
        text, phase: .awaitingRTCConfiguration
    ) else { Issue.record("Expected repaired configuration"); return }
    #expect(config.configuration?["label"] == .string("�"))
}

@Test("Missing ICE servers are allowed", arguments: [
    #"{"type":"rtcConfiguration"}"#,
    #"{"type":"rtcConfiguration","rtcConfiguration":null}"#,
    #"{"type":"rtcConfiguration","rtcConfiguration":{}}"#,
], [SignallingPhase.awaitingRTCConfiguration, .established])
func missingICEServers(text: String, phase: SignallingPhase) {
    guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(text, phase: phase) else {
        Issue.record("Expected configuration"); return
    }
    #expect(config.iceServers == nil)
}

@Test("Configuration keeps extension fields", arguments: [
    SignallingPhase.awaitingRTCConfiguration, .established,
])
func configurationExtensions(_ phase: SignallingPhase) throws {
    let text = #"{"type":"rtcConfiguration","rtcConfiguration":{"iceServers":[],"mode":"relay"}}"#
    guard case .message(let message) = ServerMessage.parse(text, phase: phase),
          case .rtcConfiguration(let config) = message else {
        Issue.record("Expected configuration"); return
    }
    #expect(config.iceServers == [])
    #expect(try jsonObject(message.toJSON()) == jsonObject(text))
}

@Test("ICE server entries normalize or reject malformed fields", arguments: [
    (#"[{"urls":"stun:example.test"}]"#, ["stun:example.test"]),
    (#"[{"urls":["stun:example.test"]}]"#, ["stun:example.test"]),
    (#"[{"urls":[1]}]"#, nil), ("[null]", nil), ("{}", nil),
    (#"[{"urls":"stun:example.test","username":1}]"#, nil),
] as [(String, [String]?)])
func iceServerEntries(servers: String, expected: [String]?) {
    let text = "{\"type\":\"rtcConfiguration\",\"rtcConfiguration\":{\"iceServers\":\(servers)}}"
    guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(text, phase: .established) else {
        Issue.record("Expected configuration"); return
    }
    #expect(config.iceServers?.first?.urls == expected)
}

@Test("Configuration fixture exposes typed ICE servers")
func typedICEServers() throws {
    let example = try #require(signallingCases(prefix: "server-rtc-").first)
    let text = String(decoding: try JSONEncoder().encode(example.json), as: UTF8.self)
    guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(text, phase: .established) else {
        Issue.record("Expected configuration"); return
    }
    #expect(config.iceServers?.count == 2)
    #expect(config.iceServers?.last?.username == "1700000000:user")
}

@Test("Open URL uses decodeURIComponent semantics", arguments: [
    ("a+b%20c", "a+b c"), ("%25", "%"), ("%F0%9F%98%80", "😀"),
    ("%", "%"), ("%GG", "%GG"), ("%E9", "%E9"), ("%ED%A0%80", "%ED%A0%80"),
    ("%C0%AF", "%C0%AF"), ("ok%20then%FF", "ok%20then%FF"),
])
func openURL(input: String, expected: String) {
    #expect(ClientMessage.OpenURL.create(suppliedURL: input, sessionID: "s").url == expected)
}

@Test("Client candidate writes explicit nulls")
func candidateNulls() throws {
    let message = ClientMessage.candidate(candidate: "c", sdpMid: nil, sdpMLineIndex: nil, sessionID: "s")
    let object = try jsonObject(message.toJSON())
    #expect(object["sdpMid"] == .null)
    #expect(object["sdpMLineIndex"] == .null)
}

@Test("Signalling timing equals the sequence fixture")
func sequenceTiming() throws {
    let sequence = try fixture("signalling/sequence.json", as: [String: JSONValue].self)
    let timing = try #require(sequence["timing"]?.objectValue)
    let actual = ["ws_open_timeout_ms": SignallingTiming.wsOpenTimeoutMs,
                  "rtc_config_timeout_ms": SignallingTiming.rtcConfigTimeoutMs,
                  "request_frame_count": SignallingTiming.requestFrameCount,
                  "request_frame_interval_ms": SignallingTiming.requestFrameIntervalMs,
                  "keep_alive_interval_ms": SignallingTiming.keepAliveIntervalMs,
                  "ice_restart_grace_ms": SignallingTiming.iceRestartGraceMs,
                  "screenshot_timeout_ms": SignallingTiming.screenshotTimeoutMs]
    #expect(timing == actual.mapValues { .number(Double($0)) })
}

@Test("Negotiated channels equal the sequence fixture", arguments: [DataChannels.control, DataChannels.hover])
func sequenceChannels(_ channel: DataChannelSpec) throws {
    let sequence = try fixture("signalling/sequence.json", as: [String: JSONValue].self)
    let channels = try #require(sequence["channels"]?.objectValue)
    let expected = try #require(channels[channel.label]?.objectValue)
    #expect(expected["label"] == .string(channel.label))
    #expect(expected["id"] == .number(Double(channel.id)))
    #expect(expected["negotiated"] == .bool(channel.negotiated))
    #expect(expected["ordered"] == .bool(channel.ordered))
    #expect(expected["maxRetransmits"] == (channel.maxRetransmits.map { .number(Double($0)) } ?? .null))
}
