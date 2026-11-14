// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
import Testing

enum RebuildTrigger: CaseIterable, Sendable {
    case socketClosed, peerFailed, peerClosed
    @MainActor func fire(socket: FakeSignalling, peer: FakePeer) {
        switch self {
        case .socketClosed: socket.onEvent?(.closed)
        case .peerFailed: peer.onEvent?(.state(.failed))
        case .peerClosed: peer.onEvent?(.state(.closed))
        }
    }
}

enum GraceTrigger: CaseIterable, Sendable {
    case deadline, terminalPeer
    @MainActor func fire(_ h: SessionHarness) {
        switch self {
        case .deadline: h.clock.advance(to: 15000)
        case .terminalPeer: h.peers[0].onEvent?(.state(.failed))
        }
    }
}

@Test("Socket close and failed peer rebuild both transports", arguments: RebuildTrigger.allCases) @MainActor
func sessionFullRebuild(trigger: RebuildTrigger) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let ws = h.sockets[0]
    let peer = h.peers[0]
    peer.onEvent?(.state(.connected))
    let staleEvent = ws.onEvent
    trigger.fire(socket: ws, peer: peer)
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
    #expect(h.credentialCalls >= 2)
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
    await settle { h.credentialCalls >= 3 }
    #expect(h.engine.status == .reconnecting(attempt: 2))
}

@Test("Refresh grace expires and terminal states bypass it", arguments: GraceTrigger.allCases) @MainActor
func sessionRefreshGrace(trigger: GraceTrigger) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let peer = h.peers[0]
    let ws = h.sockets[0]
    peer.onEvent?(.state(.connected))
    try ws.receive(h.object("server-rtc-configuration", example: 1))
    await drain()
    #expect(peer.restarts == [false])
    try ws.receive(h.object("server-rtc-configuration"))
    await settle { peer.restarts == [false, true] }
    peer.onEvent?(.state(.disconnected))
    h.clock.advance(to: 14999)
    #expect(h.engine.status == .connected)
    trigger.fire(h)
    #expect(h.engine.status == .reconnecting(attempt: 1))
}

@Test("Handshake deadlines and permanent close", arguments: [nil, SignallingEvent.opened]) @MainActor
func sessionHandshakeTimeout(event: SignallingEvent?) async throws {
    let h = try SessionHarness()
    await h.start()
    if let event { h.sockets[0].onEvent?(event) }
    h.clock.advance(to: 15000)
    #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.close()
    h.engine.retry()
    h.engine.start()
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
    await settle { h.credentialCalls >= 3 }
    h.clock.advance(to: ReconnectPolicy.stabilityMs + 1000)
    await settle { h.sockets.count == 2 }
    #expect(h.credentialCalls >= 3)
}

@Test("Dropping a session closes its transports without explicit close") @MainActor
func sessionDropClosesTransports() async throws {
    let h = try SessionHarness()
    try await h.connected()
    let socket = h.sockets[0]
    let peer = h.peers[0]
    weak var released = h.engine
    h.dropSession()
    await settle { released == nil && socket.closed && peer.closed }
}

@Test("Watchdog replaces a never-returning credentials request") @MainActor
func sessionHungCredentials() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    h.hangCredentials = true
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    h.clock.advance(to: ReconnectPolicy.connectTimeoutMs)
    await settle { h.credentialCancellations >= 1 && h.credentialCalls >= 2 }
    h.hangCredentials = false
    h.clock.advance(to: ReconnectPolicy.connectTimeoutMs + 1000)
    await settle { h.credentialCancellations >= 2 && h.sockets.count == 1 }
    #expect(h.credentialCalls >= 3)
}

@Test("Manual retry discards the budget-exhausting token prefetch") @MainActor
func sessionExhaustedTokenRetry() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    await h.start()
    for failure in 1...ReconnectPolicy.maxAttempts {
        h.sockets.last?.onEvent?(.failed(httpStatus: 401))
        let count = h.sockets.count
        h.clock.advance(to: h.clock.now + ReconnectPolicy.delayMs(attempt: failure, random: 0.5))
        await settle { h.sockets.count == count + 1 }
    }
    h.sockets.last?.onEvent?(.failed(httpStatus: 401))
    #expect(h.engine.status == .unavailable)
    let callsAtFailure = h.credentialCalls
    await settle { h.credentialCalls > callsAtFailure }
    let staleToken = "test-token-\(h.credentialCalls)"
    let socketCount = h.sockets.count
    h.engine.retry()
    await settle { h.sockets.count == socketCount + 1 }
    #expect(h.sockets.last?.credentials?.token != staleToken)
}

enum PendingPhase: CaseIterable, Sendable { case credentials, offer }

@Test("Close cancels pending credentials or offer setup", arguments: PendingPhase.allCases) @MainActor
func sessionCloseDuringSetup(phase: PendingPhase) async throws {
    let h = try SessionHarness()
    switch phase {
    case .credentials:
        h.hangCredentials = true
        h.engine.start()
        await settle { h.credentialCalls == 1 }
        h.engine.close()
        await settle { h.credentialCancellations == 1 }
        #expect(h.sockets.isEmpty)
    case .offer:
        let gate = OfferGate()
        h.offerGate = gate
        await h.start()
        h.sockets[0].onEvent?(.opened)
        try h.sockets[0].receive(h.object("server-rtc-configuration"))
        await settle { gate.continuation != nil }
        h.engine.close()
        await settle { h.peers[0].closed && gate.continuation == nil }
        #expect(h.sockets[0].frames("offer").isEmpty)
    }
    #expect(h.engine.status == .closed)
    #expect(h.clock.pendingCount == 0)
}

@Test("Late peer connection event cannot resurrect a closed socket") @MainActor
func sessionLatePeerConnected() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.connected()
    let late = h.peers[0].onEvent
    h.sockets[0].onEvent?(.closed)
    late?(.state(.connected))
    #expect(h.engine.status == .reconnecting(attempt: 1))
    #expect(h.peers[0].closed)
}

enum SessionFailure: CaseIterable, Sendable { case offer, answer, refresh, nilCredentials }

@Test("Transport failure and missing credentials paths", arguments: SessionFailure.allCases) @MainActor
func sessionFailurePaths(failure: SessionFailure) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    switch failure {
    case .nilCredentials:
        h.returnNil = true
        h.engine.start()
        await settle { h.credentialCalls == 1 }
        await drain()
        #expect(h.engine.status == .connecting)
        #expect(h.sockets.isEmpty)
    case .offer:
        h.rejectOffer = true
        await h.start()
        h.sockets[0].onEvent?(.opened)
        try h.sockets[0].receive(h.object("server-rtc-configuration"))
        await settle { h.engine.status == .reconnecting(attempt: 1) }
        #expect(h.peers[0].closed)
    case .answer:
        try await h.negotiate()
        let peer = h.peers[0]
        peer.rejectAnswer = true
        try h.sockets[0].receive(h.object("server-candidate"))
        try h.sockets[0].receive(h.object("server-answer"))
        await drain()
        #expect(peer.operations == ["configure", "offer"])
        peer.rejectAnswer = false
        try h.sockets[0].receive(h.object("server-answer"))
        await settle { peer.operations.count == 4 }
    case .refresh:
        try await h.connected()
        let peer = h.peers[0]
        peer.rejectRefresh = true
        try h.sockets[0].receive(h.object("server-rtc-configuration"))
        await settle { peer.operations.contains("refresh") }
        #expect(peer.restarts == [false])
        #expect(h.engine.status == .connected)
    }
}
