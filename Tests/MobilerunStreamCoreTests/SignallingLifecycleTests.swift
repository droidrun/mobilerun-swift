// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import Network
@testable import MobilerunStream
import MobilerunStreamCore
import Testing

@MainActor private final class LifecycleSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor private final class LoopbackSocketServer {
    let listener: NWListener
    var connection: NWConnection?
    let listening = LifecycleSignal()
    let upgraded = LifecycleSignal()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.listening.fire() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        if case .ready = state { self?.upgraded.fire() }
                    }
                }
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
    }

    func send(_ content: Data, metadata: NWProtocolWebSocket.Metadata) async throws {
        let context = NWConnection.ContentContext(identifier: "test-frame", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection!.send(content: content, contentContext: context, isComplete: true,
                             completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() {
        connection?.cancel()
        listener.cancel()
    }
}

@available(iOS 16.0, *)
@Test("Real URLSession socket receives wire close 1001 and tears down the engine",
      .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func signallingGoingAwayOnWire(provider: Bool) async throws {
    let server = try LoopbackSocketServer()
    defer { server.close() }
    await server.listening.wait()
    let port = try #require(server.listener.port?.rawValue)
    let url = URL(string: "ws://127.0.0.1:\(port)/stream")!
    let offer = LifecycleSignal()
    let disconnected = LifecycleSignal()
    let peer = FakePeer()
    peer.onOffer = { offer.fire() }
    let mint: StreamTokenProvider = { "key-a" }
    let target = StreamCredentials(url: url, token: "static-test", tokenProvider: provider ? mint : nil)
    let engine = StreamSessionEngine(credentials: { target }, scheduler: MainActorScheduler(),
                                     signalling: { URLSessionSignalling() }, peers: { peer })
    defer { engine.close() }
    engine.onStatus = { status in
        if status == .reconnecting(attempt: 1) { disconnected.fire() }
    }
    engine.start()
    await server.upgraded.wait()
    let h = try SessionHarness()
    let configuration = try JSONEncoder().encode(h.object("server-rtc-configuration"))
    try await server.send(configuration, metadata: NWProtocolWebSocket.Metadata(opcode: .text))
    await offer.wait()
    peer.onEvent?(.state(.connected))
    peer.onEvent?(.channel(id: 1, open: true))
    #expect(engine.status == .connected)
    #expect(engine.sendControl(Data([1])))
    let screenshot = Task { try await engine.screenshot() }
    await drain()
    let close = NWProtocolWebSocket.Metadata(opcode: .close)
    close.closeCode = .protocolCode(.goingAway)
    try await server.send(Data(), metadata: close)
    await disconnected.wait()
    #expect(peer.closed)
    #expect(!engine.sendControl(Data([1])))
    await #expect(throws: StreamError.disconnected) { try await screenshot.value }
}
#endif
