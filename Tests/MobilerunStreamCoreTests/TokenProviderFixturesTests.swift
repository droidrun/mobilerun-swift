// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunStreamCore
import Testing

// Literal contract scenarios until an approved conformance fixture tag is available.
private let providerURL = URL(string: "wss://stream.example.test/a?token=embedded")!

@MainActor private func providerHarness(_ provider: @escaping StreamTokenProvider) throws -> SessionHarness {
    let h = try SessionHarness()
    h.target = StreamCredentials(url: providerURL, token: "static-fallback", tokenProvider: provider)
    return h
}

@Test("A fresh provider call precedes every socket, including failed upgrades and wake") @MainActor
func sessionTokenProviderPerSocket() async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    #expect(h.sockets.isEmpty)
    await gate.waitForCall(1)
    await gate.complete(1, .success("key-a"))
    await settle { h.sockets.count == 1 }
    #expect(h.sockets[0].credentials?.token == "key-a")
    #expect(h.sockets[0].credentials?.tokenProvider == nil)
    h.sockets[0].onEvent?(.failed(httpStatus: 401))
    h.clock.advance(to: 1000)
    await drain()
    #expect(h.sockets.count == 1)
    await gate.waitForCall(2)
    await gate.complete(2, .success("key-b"))
    await settle { h.sockets.count == 2 }
    h.sockets[1].onEvent?(.failed(httpStatus: 403))
    h.engine.handleWake()
    await drain()
    await gate.waitForCall(3)
    await gate.complete(3, .success(" key-c &+%="))
    await settle { h.sockets.count == 3 }
    #expect(h.sockets[2].credentials?.token == " key-c &+%=")
    #expect(await gate.calls == 3)
}

@Test("Blank and thrown provider results never use static or embedded tokens",
      arguments: ["", " \n\t", "throw"]) @MainActor
func sessionTokenProviderFailureNoFallback(value: String) async throws {
    let h = try providerHarness {
        if value == "throw" { throw FakeFailure.negotiation }
        return value
    }
    defer { h.engine.close() }
    var diagnostics: [String] = []
    h.engine.onDiagnostic = { diagnostics.append($0) }
    h.engine.start()
    await settle { h.engine.status == .reconnecting(attempt: 1) }
    await drain()
    #expect(h.sockets.isEmpty)
    #expect(h.clock.pendingCount == 1)
    #expect(diagnostics.count == 1)
    #expect(!diagnostics.joined().contains("static-fallback"))
    h.clock.advance(to: 999)
    #expect(h.engine.status == .reconnecting(attempt: 1))
}

@Test("Independent provider deadline spans 9999/10000ms and late completion is silent",
      arguments: [false, true]) @MainActor
func sessionTokenProviderDeadline(rejectLate: Bool) async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    h.clock.advance(to: 9999)
    #expect(h.engine.status == .connecting)
    #expect(h.sockets.isEmpty)
    h.clock.advance(to: 10000)
    #expect(h.engine.status == .reconnecting(attempt: 1))
    await drain()
    #expect(h.clock.pendingCount == 1)
    let completion: Result<String, Error> = rejectLate ? .failure(FakeFailure.negotiation) : .success("late")
    await gate.waitForCall(1)
    await gate.complete(1, completion)
    await drain()
    #expect(h.sockets.isEmpty)
    #expect(h.engine.status == .reconnecting(attempt: 1))
}

@Test("Blocking provider cannot stall engine deadline or close") @MainActor
func sessionTokenProviderBlockingDeadline() async throws {
    let gate = BlockingTokenGate()
    defer { gate.unblock() }
    let h = try providerHarness { await gate.acquire() }
    h.engine.start()
    await settle { gate.started }
    h.clock.advance(to: 10000)
    #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.close()
    #expect(h.clock.pendingCount == 0)
    gate.unblock()
    await drain()
    #expect(h.sockets.isEmpty)
}

enum TokenStaleEnd: CaseIterable, Sendable { case stop, drop }

@Test("Stopped and dropped attempts ignore uncooperative providers",
      arguments: TokenStaleEnd.allCases) @MainActor
func sessionTokenProviderStaleCompletion(end: TokenStaleEnd) async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    weak var engine = h.engine
    switch end {
    case .stop: h.engine.close()
    case .drop:
        h.dropSession()
        await settle { engine == nil }
    }
    await gate.waitForCall(1)
    await gate.complete(1, .success("stale-a"))
    await drain()
    #expect(h.sockets.isEmpty)
    engine?.close()
}

@Test("Visibility changes while minting leave exactly one keepalive chain") @MainActor
func sessionTokenProviderVisibilityKeepsOneKeepAlive() async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await gate.waitForCall(1)
    h.engine.setVisible(false)
    h.engine.setVisible(true)
    await gate.complete(1, .success("key-a"))
    await settle { h.sockets.count == 1 }
    h.sockets[0].onEvent?(.opened)
    try h.sockets[0].receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 1 }
    h.clock.advance(to: 15000)
    #expect(h.sockets[0].frames("keepAlive").count == 1)
}

@Test("9000ms acquisition leaves the entire 45000ms socket watchdog", arguments: [false, true]) @MainActor
func sessionProviderWatchdogFromSocket(finalRetry: Bool) async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    var base = 0
    if finalRetry {
        for request in 1...6 {
            await gate.waitForCall(request)
            await gate.complete(request, .failure(FakeFailure.negotiation))
            await settle { h.engine.status == .reconnecting(attempt: request) }
            h.engine.handleWake()
            await drain()
        }
        base = h.clock.now
    }
    var starts = 0
    h.engine.onAttemptStarted = { starts += 1 }
    h.clock.advance(to: base + 9000)
    #expect(starts == 0)
    await gate.waitForCall(finalRetry ? 7 : 1)
    await gate.complete(finalRetry ? 7 : 1, .success("key"))
    await settle { h.sockets.count == 1 }
    #expect(starts == 1)
    h.sockets[0].onEvent?(.opened)
    try h.sockets[0].receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 1 }
    h.clock.advance(to: base + 53999)
    #expect(h.engine.status != .unavailable)
    #expect(!h.sockets[0].closed)
    h.clock.advance(to: base + 54000)
    #expect(h.sockets[0].closed)
    #expect(h.engine.status == (finalRetry ? .unavailable : .reconnecting(attempt: 1)))
}

@Test("Provider mode permits WSS and exact loopback only", arguments: [
    ("wss://stream.example.test/a", true), ("ws://localhost/a", true),
    ("ws://127.0.0.1/a", true), ("ws://[::1]/a", true),
    ("ws://localhost.evil.test/a", false), ("ws://evil-localhost/a", false),
    ("ws://localhost@evil.test/a", false), ("ws://127.0.0.2/a", false),
    ("https://localhost/a", false), ("wss:///a", false), ("ws://stream.example.test/a", false)
]) @MainActor
func sessionProviderURLPolicy(url: String, allowed: Bool) async throws {
    let gate = TokenGate()
    let h = try SessionHarness()
    defer { h.engine.close() }
    h.target = StreamCredentials(url: URL(string: url)!, tokenProvider: { try await gate.acquire() })
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    #expect(await gate.calls == (allowed ? 1 : 0))
    #expect(h.sockets.isEmpty)
    #expect(h.engine.status == (allowed ? .connecting : .reconnecting(attempt: 1)))
    h.engine.close()
    await gate.complete(1, .success("cleanup"))
}

@Test("ICE refresh and keepalive never mint; callback-only refresh does not remount") @MainActor
func sessionProviderRefreshDoesNotMint() async throws {
    let first = TokenGate()
    let next = TokenGate()
    let h = try providerHarness { try await first.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await settle { h.credentialCalls == 1 }
    await drain()
    await first.waitForCall(1)
    await first.complete(1, .success("key-a"))
    await settle { h.sockets.count == 1 }
    h.sockets[0].onEvent?(.opened)
    try h.sockets[0].receive(h.object("server-rtc-configuration"))
    await settle { h.peers.count == 1 }
    h.peers[0].onEvent?(.state(.connected))
    try h.sockets[0].receive(h.object("server-rtc-configuration"))
    await settle { h.peers[0].restarts.count == 2 }
    try #require(h.peers[0].restarts.count == 2)
    h.clock.advance(to: 15000)
    #expect(h.sockets[0].frames("keepAlive").count == 1)
    #expect(await first.calls == 1)
    h.target = StreamCredentials(url: providerURL, token: "static-fallback", tokenProvider: {
        try await next.acquire()
    })
    h.peers[0].onEvent?(.state(.disconnected))
    await settle { h.credentialCalls == 2 }
    h.peers[0].onEvent?(.state(.connected))
    await drain()
    #expect(h.sockets.count == 1)
    #expect(await next.calls == 0)
    h.sockets[0].onEvent?(.closed)
    h.engine.handleWake()
    await drain()
    await next.waitForCall(1)
    await next.complete(1, .success("key-b"))
    await settle { h.sockets.count == 2 }
    #expect(h.sockets[1].credentials?.token == "key-b")
}

@Test("Going-away transport event releases peer, control, timers and screenshots in either mode",
      arguments: [false, true]) @MainActor
func sessionGoingAwayReconnects(provider: Bool) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    if provider {
        h.target = StreamCredentials(url: providerURL, tokenProvider: { "key" })
    }
    try await h.connected()
    h.peers[0].onEvent?(.channel(id: 1, open: true))
    #expect(h.engine.sendControl(Data([1])))
    let screenshot = Task { try await h.engine.screenshot() }
    await drain()
    h.sockets[0].onEvent?(.closed)
    try #require(h.peers[0].closed)
    #expect(h.sockets[0].closed)
    #expect(!h.engine.sendControl(Data([1])))
    await #expect(throws: StreamError.disconnected) { try await screenshot.value }
    #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.handleWake()
    await settle { h.sockets.count == 2 }
}

@Test("Target replacement invalidates an in-flight key before its deadline") @MainActor
func sessionTokenProviderTargetReplacement() async throws {
    let gate = TokenGate()
    let h = try providerHarness { try await gate.acquire() }
    defer { h.engine.close() }
    h.engine.start()
    await gate.waitForCall(1)
    await gate.complete(1, .success("key-a"))
    await settle { h.sockets.count == 1 }
    h.hangCredentials = true
    h.sockets[0].onEvent?(.closed)
    await settle { h.credentialGate != nil }
    h.clock.advance(to: 1000)
    await gate.waitForCall(2)
    let targetB = StreamCredentials(url: URL(string: "wss://stream.example.test/b")!,
                                    tokenProvider: { "key-b" })
    h.credentialGate?.resume(returning: targetB)
    h.credentialGate = nil
    await settle { h.sockets.count == 2 }
    #expect(h.sockets[1].credentials?.url.path == "/b")
    #expect(h.sockets[1].credentials?.token == "key-b")
    await gate.complete(2, .success("stale-a"))
    await drain()
    #expect(h.sockets.count == 2)
    #expect(h.clock.now == 1000)
}
