// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
import Testing

@Test("Replay conformance happy path with virtual timing") @MainActor
func sessionSequenceReplay() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    await h.start()
    let ws = h.sockets[0]
    h.clock.advance(to: 300)
    ws.onEvent?(.opened)
    #expect(ws.frames("requestRtcConfiguration").count == 1)
    #expect(ws.sent[0].1["supportsLiveRtcRefresh"] == .bool(true))
    try ws.receive(h.sequenceMessage("happy_path", step: 4))
    await settle { ws.frames("offer").count == 1 }
    let peer = h.peers[0]
    #expect(peer.channels == [DataChannels.control, DataChannels.hover])
    #expect(peer.configured?.iceServers?.count == 2)
    #expect(peer.restarts == [false])
    #expect(ws.frames("offer")[0].1["sdp"] == h.object("client-offer")["sdp"])
    let localCandidate = h.sequenceMessage("happy_path", step: 8)
    peer.onEvent?(
        .candidate(
            sdp: localCandidate["candidate"]!.stringValue!,
            mid: localCandidate["sdpMid"]?.stringValue,
            index: localCandidate["sdpMLineIndex"]?.intValue))
    let expectedInitialFrames = [3, 7, 8].map { h.sequenceMessage("happy_path", step: $0) }
    for (wire, expected) in zip(ws.sent.map(\.1), expectedInitialFrames) {
        var normalized = wire
        normalized["sessionId"] = expected["sessionId"]
        #expect(normalized == expected)
    }
    peer.onEvent?(.candidate(sdp: "local", mid: nil, index: nil))
    #expect(ws.frames("candidate").last?.1["sdpMid"] == .null)
    try ws.receive(h.object("server-candidate"))
    await drain()
    #expect(!peer.operations.contains(h.object("server-candidate")["candidate"]!.stringValue!))
    try ws.receive(h.sequenceMessage("happy_path", step: 9))
    await settle { peer.operations.count == 4 }
    #expect(
        peer.operations == [
            "configure", "offer", "answer", h.object("server-candidate")["candidate"]!.stringValue!,
        ])
}

@Test("Frame requests and keep-alives follow fixture timing") @MainActor
func sessionFrameTiming() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let ws = h.sockets[0]
    let peer = h.peers[0]
    h.engine.openURL("https%3A%2F%2Fexample.test")
    h.clock.advance(to: 500)
    peer.onEvent?(.channel(id: 1, open: true))
    #expect(ws.frames("openUrl").last?.1["url"] == .string("https://example.test"))
    #expect(ws.frames("requestFrame").isEmpty)
    let timing = h.sequence["timing"]!.objectValue!
    let count = timing["request_frame_count"]!.intValue!
    let interval = timing["request_frame_interval_ms"]!.intValue!
    h.clock.advance(to: 500 + (count - 1) * interval)
    #expect(ws.frames("requestFrame").map(\.0) == (0..<count).map { 500 + $0 * interval })
    peer.onEvent?(.state(.connected))
    #expect(h.engine.status == .connected)
    h.clock.advance(to: 9999)
    #expect(ws.frames("keepAlive").isEmpty)
    h.clock.advance(to: 10000)
    #expect(ws.frames("keepAlive").map(\.0) == [10000])
    #expect(ws.frames("keepAlive").first?.0 == timing["keep_alive_interval_ms"]?.intValue)
}

@Test("Refresh exchange buffers candidates until the new answer") @MainActor
func sessionRefreshSequence() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.connected()
    let ws = h.sockets[0]
    let peer = h.peers[0]
    // Same fixture is the mid-session configuration refresh.
    try ws.receive(h.sequenceMessage("refresh", step: 1))
    await settle { peer.restarts.count == 2 }
    #expect(peer.operations.suffix(2) == ["refresh", "offer"])
    #expect(peer.restarts == [false, true])
    peer.onEvent?(.state(.connecting))
    #expect(h.engine.status == .connected)
    try ws.receive(h.object("server-candidate"))
    await drain()
    #expect(peer.operations.last == "offer")
    try ws.receive(h.sequenceMessage("refresh", step: 6))
    await settle { peer.operations.last == h.object("server-candidate")["candidate"]!.stringValue! }
    peer.onEvent?(.state(.connected))
    h.clock.advance(to: 25000)
    #expect(h.engine.status == .connected)
}

@Test("Channel sends drop unless that exact channel is open") @MainActor
func sessionChannelGuards() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let bytes = Data([1, 2])
    let peer = h.peers[0]
    #expect(!h.engine.sendControl(bytes))
    #expect(!h.engine.sendHover(bytes))
    peer.onEvent?(.channel(id: 1, open: true))
    #expect(h.engine.sendControl(bytes))
    #expect(!h.engine.sendHover(bytes))
    peer.onEvent?(.channel(id: 2, open: true))
    #expect(h.engine.sendHover(bytes))
    #expect(peer.packets.map(\.channel) == [1, 2])
    peer.onEvent?(.channel(id: 1, open: false))
    #expect(!h.engine.sendControl(bytes))
    h.engine.close()
    #expect(h.sockets[0].closeCodes.first == 1000)
    #expect(!h.engine.sendHover(bytes))
    #expect(h.clock.pendingCount == 0)
}

@Test("Malformed JSON fails startup but established sessions drop it") @MainActor
func sessionInvalidJSONPhases() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    await h.start()
    h.sockets[0].onEvent?(.opened)
    h.sockets[0].onEvent?(.message("{"))
    #expect(h.engine.status == .reconnecting(attempt: 1))
    h.clock.advance(to: 1000)
    await settle { h.sockets.count == 2 }
    let ws = h.sockets[1]
    ws.onEvent?(.opened)
    try ws.receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 1 && !ws.frames("offer").isEmpty }
    ws.onEvent?(.message("{"))
    #expect(!ws.closed)
}
