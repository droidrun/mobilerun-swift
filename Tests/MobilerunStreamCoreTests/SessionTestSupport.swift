// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
import Testing

@MainActor final class FakeSignalling: SignallingTransport {
    var onEvent: (@MainActor (SignallingEvent) -> Void)?
    var closed = false
    var credentials: StreamCredentials?
    var sent: [(Int, [String: JSONValue])] = []
    let clock: FakeClock
    init(_ clock: FakeClock) { self.clock = clock }
    func open(_ credentials: StreamCredentials) { self.credentials = credentials }
    func send(_ text: String) -> Bool {
        guard !closed, let object = try? jsonObject(text) else { return false }
        sent.append((clock.now, object))
        return true
    }
    func close() { closed = true }
    func receive(_ object: [String: JSONValue]) throws {
        onEvent?(.message(String(decoding: try JSONEncoder().encode(object), as: UTF8.self)))
    }
    func frames(_ type: String) -> [(Int, [String: JSONValue])] {
        sent.filter { $0.1["type"] == .string(type) }
    }
}

@MainActor final class OfferGate {
    var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

enum FakeFailure: Error { case negotiation }

@MainActor final class FakePeer: PeerTransport {
    var onEvent: (@MainActor (PeerEvent) -> Void)?
    var configured: ServerMessage.RTCConfiguration?
    var channels: [DataChannelSpec] = []
    var operations: [String] = []
    var restarts: [Bool] = []
    var packets: [(channel: Int, data: Data)] = []
    var closed = false
    var rejectAnswer = false
    var rejectRefresh = false
    var rejectOffer = false
    var offerGate: OfferGate?
    var onOffer: (() -> Void)?
    var offerSDP = ""
    func configure(_ config: ServerMessage.RTCConfiguration, channels: [DataChannelSpec]) {
        configured = config
        self.channels = channels
        operations.append("configure")
    }
    func createOffer(iceRestart: Bool) async throws -> String {
        if rejectOffer { throw FakeFailure.negotiation }
        restarts.append(iceRestart)
        operations.append("offer")
        onOffer?()
        try await offerGate?.wait()
        return offerSDP
    }
    func setRemoteAnswer(_ sdp: String) async throws {
        if rejectAnswer { throw FakeFailure.negotiation }
        operations.append("answer")
    }
    func addRemoteCandidate(_ candidate: ServerMessage.Candidate) async throws {
        operations.append(candidate.candidate)
    }
    func setIceServers(_ servers: [ServerMessage.ICEServer]) -> Bool {
        operations.append("refresh")
        return !rejectRefresh
    }
    func send(_ data: Data, channelID: Int) -> Bool {
        packets.append((channelID, data))
        return !closed
    }
    func close() {
        closed = true
        offerGate?.cancel()
    }
}

@MainActor final class SessionHarness {
    let clock = FakeClock()
    var sockets: [FakeSignalling] = []
    var peers: [FakePeer] = []
    var credentialCalls = 0
    var credentialCancellations = 0
    var target: StreamCredentials?
    var returnNil = false
    var hangCredentials = false
    var throwCredentials = false
    var credentialGate: CheckedContinuation<StreamCredentials?, any Error>?
    var offerGate: OfferGate?
    var rejectOffer = false
    var statuses: [StreamStatus] = []
    let cases: [SignallingCase]
    let sequence: [String: JSONValue]
    private var storedEngine: StreamSessionEngine?
    var engine: StreamSessionEngine {
        if let storedEngine { return storedEngine }
        let engine = StreamSessionEngine(
            credentials: { [weak self] in try await self?.credentials() }, scheduler: clock,
            random: { 0.5 },
            signalling: { [unowned self] in
                let socket = FakeSignalling(clock)
                sockets.append(socket)
                return socket
            },
            peers: { [unowned self] in
                let peer = FakePeer()
                peer.offerSDP = object("client-offer")["sdp"]!.stringValue!
                peer.offerGate = offerGate
                peer.rejectOffer = rejectOffer
                peers.append(peer)
                return peer
            }
        )
        engine.onStatus = { [weak self] in self?.statuses.append($0) }
        storedEngine = engine
        return engine
    }
    init() throws {
        cases = try signallingCases(prefix: "server") + signallingCases(prefix: "client")
        sequence = try fixture("signalling/sequence.json")
    }
    func credentials() async throws -> StreamCredentials? {
        credentialCalls += 1
        if throwCredentials { throw FakeFailure.negotiation }
        if hangCredentials {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { credentialGate = $0 }
            } onCancel: {
                Task { @MainActor in
                    self.credentialCancellations += 1
                    self.credentialGate?.resume(throwing: CancellationError())
                    self.credentialGate = nil
                }
            }
        }
        if let target { return target }
        return returnNil
            ? nil
            : StreamCredentials(
                url: URL(string: "wss://stream.example.test")!, token: "test-token-\(credentialCalls)"
            )
    }
    func dropSession() { storedEngine = nil }
    func sequenceMessage(_ section: String, step: Int) -> [String: JSONValue] {
        guard case .array(let steps) = sequence[section],
            let name = steps.compactMap(\.objectValue)
                .first(where: { $0["n"]?.intValue == step })?["message"]?.stringValue
        else {
            Issue.record("missing sequence step")
            return [:]
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
    func connected() async throws {
        try await negotiate()
        peers[0].onEvent?(.state(.connected))
    }
}

private let settleYieldBudget = 2000
private let drainYieldCount = 30

@MainActor func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<settleYieldBudget {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition(), "asynchronous operation did not complete")
}
@MainActor func drain() async {
    for _ in 0..<drainYieldCount { await Task.yield() }
}

/// Dumb external provider: cancellation deliberately does not complete its requests.
actor TokenGate {
    var calls = 0
    var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    func waitForCall(_ id: Int) async {
        guard calls < id else { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }
    func acquire(onCall: @Sendable () -> Void = {}) async throws -> String {
        calls += 1
        let id = calls
        onCall()
        waiting.removeValue(forKey: id)?.resume()
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func complete(_ id: Int, _ result: Result<String, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }
}

final class BlockingTokenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private let semaphore = DispatchSemaphore(value: 0)
    var started: Bool { lock.withLock { didStart } }
    func acquire() async -> String {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [self] in
                lock.withLock { didStart = true }
                semaphore.wait()
                continuation.resume(returning: "late-blocked-key")
            }
        }
    }
    func unblock() { semaphore.signal() }
}
