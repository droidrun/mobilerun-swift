// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import MobilerunStreamCore

@MainActor final class URLSessionSignalling: NSObject, SignallingTransport, URLSessionWebSocketDelegate {
    var onEvent: (@MainActor (SignallingEvent) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var failed = false

    func open(_ credentials: StreamCredentials) throws {
        guard var components = URLComponents(url: credentials.url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, ["ws", "wss"].contains(scheme), components.host != nil else {
            throw StreamError.invalidEndpoint
        }
        if let token = credentials.token {
            var query = components.queryItems ?? []
            query.removeAll { $0.name == "token" }
            query.append(URLQueryItem(name: "token", value: token))
            components.queryItems = query
        }
        guard let url = components.url else { throw StreamError.invalidEndpoint }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.socket === socket else { return }
                    switch message {
                    case .string(let text): self.onEvent?(.message(text))
                    case .data(let data): self.onEvent?(.message(String(decoding: data, as: UTF8.self)))
                    @unknown default: break
                    }
                }
            } catch { self?.reportFailure(socket) }
        }
    }
    @discardableResult func send(_ text: String) -> Bool {
        guard let socket, !failed else { return false }
        let previous = sender
        sender = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.socket === socket, !self.failed else { return }
            do { try await socket.send(.string(text)) }
            catch { self.reportFailure(socket) }
        }
        return true
    }
    func forceClose() { socket?.cancel(with: .goingAway, reason: nil) }
    func close() {
        onEvent = nil
        receiver?.cancel(); receiver = nil; sender?.cancel(); sender = nil
        let old = socket; socket = nil
        old?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel(); session = nil
    }
    private func reportFailure(_ task: URLSessionWebSocketTask) {
        guard socket === task, !failed else { return }
        failed = true
        onEvent?(.failed(httpStatus: (task.response as? HTTPURLResponse)?.statusCode))
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask, !self.failed else { return }
            self.onEvent?(.opened)
        }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask, !self.failed else { return }
            self.failed = true; self.onEvent?(.closed)
        }
    }
}
#endif
