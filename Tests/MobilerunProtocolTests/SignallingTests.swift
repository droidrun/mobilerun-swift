// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import Testing

@Test("Signalling message objects", arguments: try signallingCases())
func signallingMessage(_ item: SignallingCase) throws {
    let object = item.json
    let input = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    let output: String
    if item.file.hasPrefix("server-") {
        guard case .message(let message) = ServerMessage.parse(input, phase: .established) else {
            Issue.record("Expected parsed server message: \(item.testDescription)"); return
        }
        output = try message.toJSON()
        if case .rtcConfiguration(let config) = message {
            if item.name == "initial reply or refresh" {
                #expect(config.iceServers?.count == 2)
                #expect(config.iceServers?.last?.username == "1700000000:user")
            } else { #expect(config.iceServers == nil) }
        }
    } else {
        let message: ClientMessage
        func session() throws -> String { try #require(object["sessionId"]?.stringValue) }
        switch object["type"]?.stringValue {
        case "requestRtcConfiguration": message = try .requestRTCConfiguration(sessionID: session())
        case "offer": message = try .offer(sdp: #require(object["sdp"]?.stringValue), sessionID: session())
        case "candidate":
            message = try .candidate(candidate: #require(object["candidate"]?.stringValue),
                                     sdpMid: object["sdpMid"]?.stringValue,
                                     sdpMLineIndex: object["sdpMLineIndex"]?.intValue, sessionID: session())
        case "keepAlive": message = try .keepAlive(sessionID: session())
        case "requestFrame": message = try .requestFrame(sessionID: session())
        case "openUrl":
            message = try .openURL(.create(suppliedURL: "https%3A%2F%2Fexample.test%2Fpath%3Fq%3Da%20b", sessionID: session()))
        case "screenshot": message = try .screenshot(id: #require(object["id"]?.stringValue))
        default: Issue.record("Unhandled client fixture \(item.file)"); return
        }
        let parsed = try JSONDecoder().decode(ClientMessage.self, from: Data(input.utf8))
        #expect(parsed == message)
        #expect(try jsonObject(String(decoding: JSONEncoder().encode(parsed), as: UTF8.self)) == object)
        output = try message.toJSON()
    }
    #expect(try jsonObject(output) == object)
}

@Test("Phase-dependent invalid JSON and unknown types")
func frameRules() {
    for text in ["not json", "", "{\"type\":", "null"] {
        #expect(ServerMessage.parse(text, phase: .awaitingRTCConfiguration) == .startupFailure)
        #expect(ServerMessage.parse(text, phase: .established) == .ignored)
    }
    for text in ["42", "[]", "true", "{}", "{\"type\":7}", "{\"type\":\"future\"}", "{\"type\":\"answer\",\"sdp\":\"x\"}"] {
        #expect(ServerMessage.parse(text, phase: .awaitingRTCConfiguration) == .ignored)
    }
    for text in ["{\"type\":\"answer\"}", "{\"type\":\"screenshot\",\"id\":1,\"dataUri\":\"x\"}",
                 "{\"type\":\"screenshotError\",\"id\":\"a\"}", "{\"type\":\"future\"}",
                 "{\"type\":\"candidate\",\"candidate\":\"x\",\"sdpMLineIndex\":0.5}"] {
        #expect(ServerMessage.parse(text, phase: .established) == .ignored)
    }
    #expect(ServerMessage.parse("{\"type\":\"rtcConfiguration\",\"rtcConfiguration\":\"bad\"}", phase: .awaitingRTCConfiguration) == .startupFailure)
    #expect(ServerMessage.parse("{\"type\":\"answer\",\"sdp\":\"x\",\"extra\":1}", phase: .established)
            == ServerMessage.parse("{\"type\":\"answer\",\"sdp\":\"x\"}", phase: .established))
}

@Test("Configuration preserves extension fields and handles refresh ICE servers")
func configurationRules() throws {
    for phase in [SignallingPhase.awaitingRTCConfiguration, .established] {
        for config in ["", ",\"rtcConfiguration\":null", ",\"rtcConfiguration\":{}"] {
            guard case .message(.rtcConfiguration(let message)) = ServerMessage.parse("{\"type\":\"rtcConfiguration\"\(config)}", phase: phase) else {
                Issue.record("Configuration missing ICE servers should parse"); continue
            }
            #expect(message.iceServers == nil)
        }
        let text = "{\"type\":\"rtcConfiguration\",\"rtcConfiguration\":{\"iceServers\":[],\"iceTransportPolicy\":\"relay\"}}"
        guard case .message(let message) = ServerMessage.parse(text, phase: phase),
              case .rtcConfiguration(let config) = message else { Issue.record("Expected configuration"); continue }
        #expect(config.iceServers == [])
        #expect(try jsonObject(message.toJSON()) == jsonObject(text))
    }
    for (servers, valid) in [("[{\"urls\":\"stun:example.test\"}]", true),
                             ("[{\"urls\":[\"stun:example.test\"]}]", true),
                             ("[{\"urls\":[1]}]", false), ("[null]", false), ("{}", false)] {
        let text = "{\"type\":\"rtcConfiguration\",\"rtcConfiguration\":{\"iceServers\":\(servers)}}"
        guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(text, phase: .established) else {
            Issue.record("Expected configuration"); continue
        }
        #expect((config.iceServers != nil) == valid)
        if valid { #expect(config.iceServers?.first?.urls == ["stun:example.test"]) }
    }
}

@Test("Open URL uses decodeURIComponent semantics", arguments: [
    ("a+b%20c", "a+b c"), ("%25", "%"), ("%F0%9F%98%80", "😀"),
    ("%", "%"), ("%GG", "%GG"), ("%E9", "%E9"), ("%ED%A0%80", "%ED%A0%80"),
    ("%C0%AF", "%C0%AF"), ("ok%20then%FF", "ok%20then%FF")
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

@Test("Decoded URL wire frames are not percent-decoded twice")
func wireURL() throws {
    let text = "{\"type\":\"openUrl\",\"url\":\"https://example.test/%2520%25\",\"sessionId\":\"s\"}"
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    #expect(try jsonObject(message.toJSON()) == jsonObject(text))
}

@Test("Signalling timing and channel contract equals sequence fixture")
func sequenceContract() throws {
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
    let channels = try #require(sequence["channels"]?.objectValue)
    for channel in [DataChannels.control, DataChannels.hover] {
        let expected = try #require(channels[channel.label]?.objectValue)
        #expect(expected["label"] == .string(channel.label))
        #expect(expected["id"] == .number(Double(channel.id)))
        #expect(expected["negotiated"] == .bool(channel.negotiated))
        #expect(expected["ordered"] == .bool(channel.ordered))
        #expect(expected["maxRetransmits"] == (channel.maxRetransmits.map { .number(Double($0)) } ?? .null))
    }
}
