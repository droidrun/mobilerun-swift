// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import MobilerunProtocol
@_spi(Testing) import MobilerunStreamCore

@MainActor private final class FakeSignalling: SignallingTransport {
    var onEvent: (@MainActor (SignallingEvent) -> Void)?
    var closed = false
    var credentials: StreamCredentials?
    var sent: [(Int, [String: JSONValue])] = []
    let clock: FakeClock
    init(_ clock: FakeClock) { self.clock = clock }
    func open(_ credentials: StreamCredentials) { self.credentials = credentials }
    func send(_ text: String) -> Bool {
        guard !closed, let object = try? jsonObject(text) else { return false }
        sent.append((clock.now, object)); return true
    }
    func close() { closed = true }
    func receive(_ object: [String: JSONValue]) throws {
        onEvent?(.message(String(decoding: try JSONEncoder().encode(object), as: UTF8.self)))
    }
    func frames(_ type: String) -> [(Int, [String: JSONValue])] { sent.filter { $0.1["type"] == .string(type) } }
}
@MainActor private final class FakePeer: PeerTransport {
    var onEvent: (@MainActor (PeerEvent) -> Void)?
    var configured: ServerMessage.RTCConfiguration?
    var channels: [DataChannelSpec] = []
    var operations: [String] = []
    var restarts: [Bool] = []
    var sends: [Int] = []
    var closed = false
    var rejectAnswer = false
    var rejectRefresh = false
    var rejectOffer = false
    var offerSDP = ""
    func configure(_ config: ServerMessage.RTCConfiguration, channels: [DataChannelSpec]) {
        configured = config; self.channels = channels; operations.append("configure")
    }
    func createOffer(iceRestart: Bool) async throws -> String {
        if rejectOffer { throw StreamError.negotiationFailed }
        restarts.append(iceRestart); operations.append("offer"); return offerSDP
    }
    func setRemoteAnswer(_ sdp: String) async throws {
        if rejectAnswer { throw StreamError.negotiationFailed }
        operations.append("answer")
    }
    func addRemoteCandidate(_ candidate: ServerMessage.Candidate) async throws { operations.append(candidate.candidate) }
    func setIceServers(_ servers: [ServerMessage.ICEServer]) -> Bool {
        operations.append("refresh"); return !rejectRefresh
    }
    func send(_ data: Data, channelID: Int) -> Bool { sends.append(channelID); return !closed }
    func close() { closed = true }
}
@MainActor private final class SessionHarness {
    let clock = FakeClock()
    var sockets: [FakeSignalling] = []
    var peers: [FakePeer] = []
    var credentialCalls = 0
    var returnNil = false
    var statuses: [StreamStatus] = []
    let cases: [SignallingCase]
    let sequence: [String: JSONValue]
    lazy var engine: StreamSessionEngine = {
        let engine = StreamSessionEngine(credentials: { [weak self] in await self?.credentials() }, scheduler: clock,
            random: { 0.5 }, signalling: { [unowned self] in
                let socket = FakeSignalling(clock); sockets.append(socket); return socket
            }, peers: { [unowned self] in
                let peer = FakePeer()
                peer.offerSDP = object("client-offer")["sdp"]!.stringValue!
                peers.append(peer); return peer
            })
        engine.onStatus = { [weak self] in self?.statuses.append($0) }
        return engine
    }()
    init() throws {
        cases = try signallingCases(prefix: "server") + signallingCases(prefix: "client")
        sequence = try fixture("signalling/sequence.json")
    }
    func credentials() -> StreamCredentials? {
        credentialCalls += 1
        return returnNil ? nil : StreamCredentials(url: URL(string: "wss://stream.example.test")!, token: "test-token")
    }
    func sequenceMessage(_ section: String, step: Int) -> [String: JSONValue] {
        guard case .array(let steps) = sequence[section],
              let name = steps.compactMap(\.objectValue).first(where: { $0["n"]?.intValue == step })?["message"]?.stringValue else {
            Issue.record("missing sequence step"); return [:]
        }
        return object(name)
    }
    func object(_ name: String, example: Int = 0) -> [String: JSONValue] {
        cases.filter { $0.file == name + ".json" }[example].json
    }
    func start() async {
        engine.start()
        await settle { !self.sockets.isEmpty }
    }
    func negotiate() async throws {
        await start()
        sockets[0].onEvent?(.opened)
        try sockets[0].receive(object("server-rtc-configuration"))
        await settle { !self.peers.isEmpty && !self.sockets[0].frames("offer").isEmpty }
    }
}
@MainActor private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition(), "asynchronous operation did not complete")
}
@MainActor private func drain() async { for _ in 0..<30 { await Task.yield() } }

@Test("Replay conformance happy path and refresh with virtual timing") @MainActor
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
    peer.onEvent?(.candidate(sdp: localCandidate["candidate"]!.stringValue!,
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
    #expect(peer.operations == ["configure", "offer", "answer", h.object("server-candidate")["candidate"]!.stringValue!])
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
    #expect(ws.frames("keepAlive").first?.0 == timing["keep_alive_interval_ms"]?.intValue)
}

@Test("Socket close and failed peer rebuild both transports", arguments: [true, false]) @MainActor
func sessionFullRebuild(socketLoss: Bool) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let ws = h.sockets[0], peer = h.peers[0]
    peer.onEvent?(.state(.connected))
    let staleEvent = ws.onEvent
    if socketLoss { ws.onEvent?(.closed) } else { peer.onEvent?(.state(.failed)) }
    #expect(h.engine.status == .reconnecting(attempt: 1))
    #expect(ws.closed && peer.closed)
    await settle { h.credentialCalls == 2 }
    h.clock.advance(to: 999)
    #expect(h.sockets.count == 1)
    h.clock.advance(to: 1000)
    await settle { h.sockets.count == 2 }
    h.sockets[1].onEvent?(.opened)
    try h.sockets[1].receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 2 && h.peers[1].restarts.count == 1 }
    #expect(h.sockets[1].frames("requestRtcConfiguration").count == 1)
    staleEvent?(.closed)
    h.peers[1].onEvent?(.state(.connected))
    #expect(h.engine.status == .connected)
    #expect(h.credentialCalls == 2)
}

@Test("Rejected tokens refetch even within an existing recovery cycle") @MainActor
func sessionRejectedToken() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    await h.start()
    h.sockets[0].onEvent?(.failed(httpStatus: 401))
    await settle { h.credentialCalls == 2 }
    h.clock.advance(to: 1000)
    await settle { h.sockets.count == 2 }
    h.sockets[1].onEvent?(.failed(httpStatus: 401))
    await settle { h.credentialCalls == 3 }
    #expect(h.engine.status == .reconnecting(attempt: 2))
}

@Test("Channel sends drop unless that exact channel is open") @MainActor
func sessionChannelGuards() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let bytes = Data([1, 2]), peer = h.peers[0]
    #expect(!h.engine.sendControl(bytes)); #expect(!h.engine.sendHover(bytes))
    peer.onEvent?(.channel(id: 1, open: true))
    #expect(h.engine.sendControl(bytes)); #expect(!h.engine.sendHover(bytes))
    peer.onEvent?(.channel(id: 2, open: true))
    #expect(h.engine.sendHover(bytes)); #expect(peer.sends == [1, 2])
    peer.onEvent?(.channel(id: 1, open: false))
    #expect(!h.engine.sendControl(bytes))
    h.engine.close()
    #expect(!h.engine.sendHover(bytes)); #expect(h.clock.pendingCount == 0)
}

@Test("Screenshot replies, errors, timeout, cancellation and disconnect settle callers") @MainActor
func sessionScreenshots() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let ws = h.sockets[0]
    let success = Task { try await h.engine.screenshot(timeout: 2) }
    await settle { ws.frames("screenshot").count == 1 }
    let id = ws.frames("screenshot")[0].1["id"]!
    try ws.receive(["type": .string("screenshot"), "id": id, "dataUri": .string("data:image/png;base64,AQID")])
    #expect(try await success.value == Data([1, 2, 3]))
    let timeout = Task { try await h.engine.screenshot(timeout: 2) }
    await settle { ws.frames("screenshot").count == 2 }
    h.clock.advance(to: 2000)
    do { _ = try await timeout.value; Issue.record("expected timeout") }
    catch { #expect(error as? StreamError == .screenshotTimeout) }
    let cancelled = Task { try await h.engine.screenshot() }
    await settle { ws.frames("screenshot").count == 3 }
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("expected cancellation") }
    catch { #expect(error is CancellationError) }
    let failure = Task { try await h.engine.screenshot() }
    await settle { ws.frames("screenshot").count == 4 }
    try ws.receive(["type": .string("screenshotError"), "id": ws.frames("screenshot")[3].1["id"]!, "message": .string("failed")])
    do { _ = try await failure.value; Issue.record("expected screenshot error") }
    catch { #expect(error as? StreamError == .screenshotFailed) }
    let pending = Task { try await h.engine.screenshot() }
    await settle { ws.frames("screenshot").count == 5 }
    h.engine.close()
    do { _ = try await pending.value; Issue.record("expected disconnect") }
    catch { #expect(error as? StreamError == .disconnected) }
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

@Test("Refresh grace expires and terminal states bypass it", arguments: [true, false]) @MainActor
func sessionRefreshGrace(terminal: Bool) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let peer = h.peers[0], ws = h.sockets[0]
    peer.onEvent?(.state(.connected))
    try ws.receive(h.object("server-rtc-configuration", example: 1))
    await drain()
    #expect(peer.restarts == [false])
    try ws.receive(h.object("server-rtc-configuration"))
    await settle { peer.restarts == [false, true] }
    peer.onEvent?(.state(.disconnected))
    h.clock.advance(to: 14999)
    #expect(h.engine.status == .connected)
    if terminal { peer.onEvent?(.state(.failed)) }
    else { h.clock.advance(to: 15000) }
    #expect(h.engine.status == .reconnecting(attempt: 1))
}

@Test("Handshake deadlines and permanent close", arguments: [true, false]) @MainActor
func sessionHandshakeTimeout(opened: Bool) async throws {
    let h = try SessionHarness()
    await h.start()
    if opened { h.sockets[0].onEvent?(.opened) }
    h.clock.advance(to: 15000)
    #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.close(); h.engine.retry(); h.engine.start()
    h.clock.advance(to: 200000)
    #expect(h.engine.status == .closed)
    #expect(h.sockets.count == 1)
    #expect(h.clock.pendingCount == 0)
}

@Test("Self recovery discards unused credentials before the next heal") @MainActor
func sessionRecoveryCredentials() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let peer = h.peers[0]
    peer.onEvent?(.state(.connected))
    peer.onEvent?(.state(.disconnected))
    await settle { h.credentialCalls == 2 }
    peer.onEvent?(.state(.connected))
    h.clock.advance(to: ReconnectPolicy.stabilityMs)
    #expect(h.sockets.count == 1)
    peer.onEvent?(.state(.failed))
    await settle { h.credentialCalls == 3 }
    h.clock.advance(to: ReconnectPolicy.stabilityMs + 1000)
    await settle { h.sockets.count == 2 }
    #expect(h.credentialCalls == 3)
}
