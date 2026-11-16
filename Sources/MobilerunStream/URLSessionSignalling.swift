// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import Foundation
    import MobilerunStreamCore

    @MainActor final class URLSessionSignalling: SignallingTransport {
        var onEvent: (@MainActor (SignallingEvent) -> Void)?
        private var session: URLSession?
        private var socket: URLSessionWebSocketTask?
        private var receiver: Task<Void, Never>?
        private var sender: Task<Void, Never>?
        private var failed = false
        #if DEBUG
            var onDiagnostic: (@MainActor (String) -> Void)?
        #endif

        func open(_ credentials: StreamCredentials) throws {
            let url = try Self.endpoint(credentials)
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            let session = URLSession(
                configuration: config, delegate: DelegateProxy(owner: self), delegateQueue: nil)
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
        static func endpoint(_ credentials: StreamCredentials) throws -> URL {
            guard var components = URLComponents(url: credentials.url, resolvingAgainstBaseURL: false),
                let scheme = components.scheme, ["ws", "wss"].contains(scheme), components.host != nil
            else {
                throw SignallingError.invalidEndpoint
            }
            if let token = credentials.token, !token.isEmpty {
                // Preserve existing query bytes; only the replacement token is encoded.
                var query = components.percentEncodedQuery?.components(separatedBy: "&") ?? []
                query.removeAll { $0.components(separatedBy: "=")[0].removingPercentEncoding == "token" }
                let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                    throw SignallingError.invalidEndpoint
                }
                query.append("token=" + encodedToken)
                components.percentEncodedQuery = query.joined(separator: "&")
            }
            guard let url = components.url else { throw SignallingError.invalidEndpoint }
            return url
        }
        @discardableResult func send(_ text: String) -> Bool {
            guard let socket, !failed else { return false }
            let previous = sender
            sender = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, let self, self.socket === socket, !self.failed else { return }
                do { try await socket.send(.string(text)) } catch { self.reportFailure(socket) }
            }
            return true
        }
        #if DEBUG
            func forceClose() { socket?.cancel(with: .goingAway, reason: nil) }
        #endif

        deinit { session?.invalidateAndCancel() }
        func close() {
            onEvent = nil
            receiver?.cancel()
            receiver = nil
            sender?.cancel()
            sender = nil
            let old = socket
            socket = nil
            old?.cancel(with: .normalClosure, reason: nil)
            // Let URLSession transmit the normal (1000) close frame before invalidation.
            session?.finishTasksAndInvalidate()
            session = nil
        }
        private func reportFailure(_ task: URLSessionWebSocketTask) {
            guard socket === task, !failed else { return }
            failed = true
            onEvent?(.failed(httpStatus: (task.response as? HTTPURLResponse)?.statusCode))
        }
        private final class DelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
            private weak var owner: URLSessionSignalling?
            #if DEBUG
                private let onDiagnostic: (@MainActor (String) -> Void)?
            #endif

            @MainActor init(owner: URLSessionSignalling) {
                self.owner = owner
                #if DEBUG
                    onDiagnostic = owner.onDiagnostic
                #endif
            }

            nonisolated func urlSession(
                _ session: URLSession,
                webSocketTask: URLSessionWebSocketTask,
                didOpenWithProtocol protocol: String?
            ) {
                Task { @MainActor [weak owner] in
                    guard let owner, owner.socket === webSocketTask, !owner.failed else { return }
                    owner.onEvent?(.opened)
                }
            }

            nonisolated func urlSession(
                _ session: URLSession,
                webSocketTask: URLSessionWebSocketTask,
                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                reason: Data?
            ) {
                Task { @MainActor [weak owner, self] in
                    #if DEBUG
                        onDiagnostic?("websocket closed code=\(closeCode.rawValue)")
                    #endif
                    guard let owner, owner.socket === webSocketTask, !owner.failed else { return }
                    owner.failed = true
                    owner.onEvent?(.closed)
                }
            }
        }
    }

    private enum SignallingError: Error { case invalidEndpoint }
#endif
