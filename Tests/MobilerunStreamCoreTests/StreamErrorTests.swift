// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunStreamCore
import Testing

private let errorURL = URL(string: "wss://stream.example.test/a")!

@MainActor private func collect(_ h: SessionHarness) -> ErrorLog {
    let log = ErrorLog()
    h.engine.onError = { log.errors.append($0) }
    return log
}

@MainActor final class ErrorLog { var errors: [StreamConnectionError] = [] }

enum ErrorDrop: CaseIterable, Sendable, CustomTestStringConvertible {
    case closedBeforeOpen, failedWithoutStatus, unauthorized, forbidden, notFound, serverError
    var testDescription: String { String(describing: self) }
    var event: SignallingEvent {
        switch self {
        case .closedBeforeOpen: .closed
        case .failedWithoutStatus: .failed(httpStatus: nil)
        case .unauthorized: .failed(httpStatus: 401)
        case .forbidden: .failed(httpStatus: 403)
        case .notFound: .failed(httpStatus: 404)
        case .serverError: .failed(httpStatus: 503)
        }
    }
    var reason: StreamErrorReason {
        switch self {
        case .closedBeforeOpen, .failedWithoutStatus, .serverError: .connectionRefused
        case .unauthorized, .forbidden: .tokenRejected
        case .notFound: .deviceUnavailable
        }
    }
}

@Test("A socket that never opened reports the reason its upgrade failed", arguments: ErrorDrop.allCases) @MainActor
func errorReasonBeforeOpen(drop: ErrorDrop) async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    let log = collect(h)
    await h.start()
    h.sockets[0].onEvent?(drop.event)
    await drain()
    #expect(log.errors == [StreamConnectionError(
        reason: drop.reason, message: drop.reason.defaultMessage, attempt: 1, final: false)])
}

@Test("An open session that drops reports disconnected, from the socket or the peer",
      arguments: [false, true]) @MainActor
func errorReasonAfterOpen(peerDrop: Bool) async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    let log = collect(h)
    try await h.connected()
    #expect(log.errors.isEmpty)
    if peerDrop { h.peers[0].onEvent?(.state(.failed)) } else { h.sockets[0].onEvent?(.closed) }
    await drain()
    #expect(log.errors.map(\.reason) == [.disconnected])
    #expect(log.errors.first?.final == false)
}

@Test("A provider that throws or times out reports credentials_unavailable", arguments: [false, true]) @MainActor
func errorReasonProvider(timeout: Bool) async throws {
    let gate = TokenGate()
    let h = try SessionHarness(); defer { h.engine.close() }
    h.target = StreamCredentials(url: errorURL, tokenProvider: {
        if timeout { return try await gate.acquire() }
        throw FakeFailure.negotiation
    })
    let log = collect(h)
    h.engine.start()
    if timeout {
        await gate.waitForCall(1)
        h.clock.advance(to: ReconnectPolicy.providerTimeoutMs)
    }
    await settle { !log.errors.isEmpty }
    #expect(log.errors.map(\.reason) == [.credentialsUnavailable])
    #expect(h.sockets.isEmpty)
}

@Test("Attempts count up and only the one that exhausts the budget is final") @MainActor
func errorFinalAfterBudget() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    let log = collect(h)
    await h.start()
    for failure in 1...ReconnectPolicy.maxAttempts {
        h.sockets.last?.onEvent?(.closed)
        await drain()
        #expect(log.errors.count == failure)
        let count = h.sockets.count
        h.clock.advance(to: h.clock.now + ReconnectPolicy.delayMs(attempt: failure, random: 0.5))
        #expect(h.sockets.count == count + 1)
    }
    #expect(log.errors.allSatisfy { !$0.final })
    h.sockets.last?.onEvent?(.closed)
    await drain()
    #expect(h.engine.status == .unavailable)
    #expect(log.errors.map(\.attempt) == Array(1...(ReconnectPolicy.maxAttempts + 1)))
    #expect(log.errors.last?.final == true)
    // A manual retry starts a fresh cycle without reporting an error of its own.
    h.engine.retry()
    await drain()
    #expect(log.errors.count == ReconnectPolicy.maxAttempts + 1)
}

@Test("Every connect attempt asks the provider and never reuses an earlier key") @MainActor
func errorProviderNeverReusesKey() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    let counter = KeyCounter()
    h.target = StreamCredentials(url: errorURL, tokenProvider: { await counter.next() })
    await h.start()
    h.sockets[0].onEvent?(.opened)
    h.sockets[0].onEvent?(.closed) // an open session drops
    await drain()
    h.clock.advance(to: ReconnectPolicy.delayMs(attempt: 1, random: 0.5))
    await settle { h.sockets.count == 2 }
    h.sockets[1].onEvent?(.failed(httpStatus: 401))
    await drain()
    h.clock.advance(to: h.clock.now + ReconnectPolicy.delayMs(attempt: 2, random: 0.5))
    await settle { h.sockets.count == 3 }
    let keys = h.sockets.compactMap { $0.credentials?.token }
    #expect(keys == ["key-1", "key-2", "key-3"])
    #expect(await counter.calls == 3)
}

actor KeyCounter {
    var calls = 0
    func next() -> String { calls += 1; return "key-\(calls)" }
}

@Test("A static token still connects and warns exactly once per session") @MainActor
func errorStaticTokenWarnsOnce() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    var warnings: [String] = []
    h.engine.onWarning = { warnings.append($0) }
    h.target = StreamCredentials(url: errorURL, token: "static-key")
    await h.start()
    #expect(h.sockets[0].credentials?.token == "static-key")
    h.sockets[0].onEvent?(.closed)
    await drain()
    h.clock.advance(to: ReconnectPolicy.delayMs(attempt: 1, random: 0.5))
    await settle { h.sockets.count == 2 }
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("tokenProvider") == true)
    #expect(!warnings.joined().contains("static-key"))
}

@Test("A token provider never triggers the deprecation warning") @MainActor
func errorProviderDoesNotWarn() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    var warnings: [String] = []
    h.engine.onWarning = { warnings.append($0) }
    h.target = StreamCredentials(url: errorURL, token: "ignored", tokenProvider: { "fresh" })
    await h.start()
    #expect(h.sockets[0].credentials?.token == "fresh")
    #expect(warnings.isEmpty)
}
