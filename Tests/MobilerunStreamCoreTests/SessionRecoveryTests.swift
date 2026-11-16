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
    #expect(h.engine.status == .reconnecting(attempt: 1))
    #expect(h.sockets.count == 1)
    #expect(h.clock.pendingCount == 0)
}

@Test("Heal prefetch survives remount and its result is reused") @MainActor
func sessionRecoveryCredentials() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    try await h.connected()
    let original = h.sockets[0].credentials?.token
    h.hangCredentials = true
    h.peers[0].onEvent?(.state(.disconnected))
    await settle { h.credentialCalls == 2 }
    h.clock.advance(to: 1000)
    #expect(h.sockets.count == 2)
    #expect(h.sockets[1].credentials?.token == original)
    #expect(h.credentialCancellations == 0)
    // Complete the same in-flight heal after remount; do not call the provider again.
    h.credentialGate?.resume(returning: StreamCredentials(url: URL(string: "wss://stream.example.test")!, token: "fresh"))
    h.credentialGate = nil
    await settle { h.sockets.count == 3 }
    #expect(h.sockets.last?.credentials?.token == "fresh")
    #expect(h.credentialCalls == 2)
    h.sockets.last?.onEvent?(.closed)
    h.clock.advance(to: h.clock.now + ReconnectPolicy.delayMs(attempt: 2, random: 0.5))
    #expect(h.sockets.last?.credentials?.token == "fresh")
    #expect(h.credentialCalls == 2)
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

@Test("Provider deadline releases a hung request before initial polling resumes") @MainActor
func sessionHungCredentials() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    h.hangCredentials = true
    h.engine.start(); await settle { h.credentialCalls == 1 }
    h.clock.advance(to: ReconnectPolicy.connectTimeoutMs)
    await settle { h.credentialCancellations == 1 }
    #expect(h.engine.status == .connecting)
    h.hangCredentials = false
    h.clock.advance(to: ReconnectPolicy.connectTimeoutMs + 2999)
    #expect(h.credentialCalls == 1)
    h.clock.advance(to: ReconnectPolicy.connectTimeoutMs + 3000)
    await settle { h.sockets.count == 1 }
    #expect(h.credentialCalls == 2)
}

@Test("Nil after a target cannot bypass the retry budget; Retry reuses cached credentials") @MainActor
func sessionExhaustedTokenRetry() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    try await h.connected()
    let token = h.sockets[0].credentials?.token
    h.returnNil = true
    for failure in 1...ReconnectPolicy.maxAttempts {
        h.sockets.last?.onEvent?(.closed)
        await drain()
        let count = h.sockets.count
        h.clock.advance(to: h.clock.now + ReconnectPolicy.delayMs(attempt: failure, random: 0.5))
        #expect(h.sockets.count == count + 1)
        #expect(h.sockets.last?.credentials?.token == token)
    }
    h.sockets.last?.onEvent?(.closed)
    #expect(h.engine.status == .unavailable)
    let count = h.sockets.count
    h.engine.retry()
    #expect(h.sockets.count == count + 1)
    #expect(h.sockets.last?.credentials?.token == token)
    h.peers.last?.onEvent?(.state(.connected)) // The released peer cannot revive the old mount.
    #expect(h.engine.status == .reconnecting(attempt: 0))
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
    #expect(h.engine.status == .connecting)
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

@Test("Credentials poll at 3000ms without consuming recovery budget") @MainActor
func sessionCredentialsPoll() async throws {
    let h = try SessionHarness(); h.returnNil = true
    h.engine.start(); await settle { h.credentialCalls == 1 }; await drain()
    #expect(h.engine.status == .connecting)
    for n in 1...12 {
        h.clock.advance(to: n * 3000 - 1); #expect(h.credentialCalls == n)
        h.clock.advance(to: n * 3000); await settle { h.credentialCalls == n + 1 }; await drain()
        #expect(h.engine.status == .connecting)
    }
    h.returnNil = false; h.engine.handleWake()
    await settle { h.sockets.count == 1 }
    h.engine.close(); h.clock.advance(to: 100000); await drain()
    #expect(h.credentialCalls == 14)
}

@Test("Background stops keepalive; foreground resumes and wake skips backoff") @MainActor
func sessionLifecycle() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    try await h.connected(); let ws = h.sockets[0]
    h.engine.setVisible(false); h.clock.advance(to: 30000)
    #expect(ws.frames("keepAlive").isEmpty)
    h.engine.setVisible(true); h.clock.advance(to: 40000)
    #expect(ws.frames("keepAlive").count == 1)
    ws.onEvent?(.closed); #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.handleWake(); await settle { h.sockets.count == 2 }
}

@Test("Initial provider throws poll as nil; a hung heal cannot stall the recovery budget") @MainActor
func sessionProviderFailures() async throws {
    let initial = try SessionHarness(); defer { initial.engine.close() }
    initial.throwCredentials = true
    initial.engine.start(); await settle { initial.credentialCalls == 1 }; await drain()
    #expect(initial.engine.status == .connecting)
    initial.clock.advance(to: 3000); await settle { initial.credentialCalls == 2 }; await drain()
    #expect(initial.sockets.isEmpty)
    initial.throwCredentials = false
    initial.clock.advance(to: 6000); await settle { initial.sockets.count == 1 }

    let recovery = try SessionHarness(); defer { recovery.engine.close() }
    try await recovery.connected()
    recovery.hangCredentials = true
    recovery.sockets[0].onEvent?(.closed)
    await settle { recovery.credentialCalls == 2 }
    for _ in 0..<20 {
        recovery.clock.advance(to: recovery.clock.now + ReconnectPolicy.connectTimeoutMs)
        await drain()
        if recovery.engine.status == .unavailable { break }
    }
    #expect(recovery.engine.status == .unavailable)
    #expect(recovery.credentialCalls == 2)
    #expect(recovery.credentialCancellations == 1)
}

@Test("Connected credential refresh only remounts for a changed URL", arguments: [
    ("wss://stream.example.test", 2, false),
    ("wss://changed.example.test", 3, true),
]) @MainActor
func sessionConnectedCredentialRefresh(refreshedURL: String, mountCount: Int, previousClosed: Bool) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.connected()
    h.hangCredentials = true
    h.peers[0].onEvent?(.state(.disconnected))
    await settle { h.credentialGate != nil }
    h.clock.advance(to: 1000)
    h.sockets[1].onEvent?(.opened)
    try h.sockets[1].receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 2 }
    h.peers[1].onEvent?(.state(.connected))
    h.credentialGate?.resume(returning: StreamCredentials(url: URL(string: refreshedURL)!, token: "refreshed-token"))
    h.credentialGate = nil
    await drain()
    #expect(h.sockets.count == mountCount)
    #expect(h.sockets[1].credentials?.token == "test-token-1")
    #expect(h.sockets[1].closed == previousClosed)
    // A later mount must use the stored token even when the healthy connection was retained.
    h.sockets.last?.onEvent?(.closed)
    await drain()
    h.clock.advance(to: h.clock.now + 60_000)
    #expect(h.sockets.last?.credentials?.token == "refreshed-token")
    #expect(h.sockets.last?.credentials?.url.absoluteString == refreshedURL)
}
