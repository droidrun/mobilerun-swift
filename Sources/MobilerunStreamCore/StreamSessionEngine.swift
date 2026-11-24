// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// Transport-independent session. Every attempt owns its timers, messages and peer.
@MainActor package final class StreamSessionEngine {
    package private(set) var status: StreamStatus = .connecting {
        didSet {
            if status != oldValue { onStatus?(status) }
        }
    }
    package var onStatus: (@MainActor (StreamStatus) -> Void)?
    package var onAttemptStarted: (@MainActor () -> Void)?
    /// Reports every counted failure; `final` marks the one that exhausts the retry budget.
    package var onError: (@MainActor (StreamConnectionError) -> Void)?
    /// Receives the one-per-session deprecation notice for static tokens.
    package var onWarning: @MainActor (String) -> Void = { StreamLog.warn($0) }
    private var warnedStaticToken = false
    private var pendingReason: StreamErrorReason?
    /// Raw peer connectivity, including dips hidden by the public ICE-refresh grace period.
    package var onPeerConnectivity: (@MainActor (Bool) -> Void)?
    #if DEBUG
        package var onDiagnostic: (@MainActor (String) -> Void)?
    #endif
    package let publisher: PublishController
    private let credentials: StreamCredentialsProvider
    private let signalling: @MainActor () -> any SignallingTransport
    private let peers: @MainActor () -> any PeerTransport
    private let scheduler: any ReconnectScheduler
    private let random: () -> Double
    private var hidden = false
    private var credentialPoll: (any ScheduledTask)?
    private var started = false
    private var closed = false
    private var attempt: Attempt?
    private var credentialTask: Task<Void, Never>?
    private var credentialDeadline: (any ScheduledTask)?
    private var credentialGeneration = 0
    private var latestTarget: StreamCredentials?
    private var activeTarget: StreamCredentials?
    private static let credentialPollIntervalMs = 3000
    private var pendingURL: String?
    private var controller: StreamReconnectController?

    package init(
        credentials: @escaping StreamCredentialsProvider,
        scheduler: any ReconnectScheduler,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        publishCapabilities: DevicePublishCapabilities? = nil,
        signalling: @escaping @MainActor () -> any SignallingTransport,
        peers: @escaping @MainActor () -> any PeerTransport
    ) {
        self.publisher = PublishController(capabilities: publishCapabilities, scheduler: scheduler)
        self.credentials = credentials
        self.scheduler = scheduler
        self.random = random
        self.signalling = signalling
        self.peers = peers
        publisher.onError = { [weak self] failure, id in
            guard let self, !self.closed else { return }
            self.onError?(StreamConnectionError(
                reason: StreamErrorReason(rawValue: failure.reason.rawValue) ?? .publishFailed,
                message: failure.message, attempt: self.controller?.snapshot.attempt ?? 0, final: true,
                operation: "publish", mediaSessionId: id, detail: failure.detail, serverReason: failure.serverReason))
        }
    }

    deinit {
        credentialTask?.cancel()
        let publisher = publisher
        let attempt = attempt
        let controller = controller
        let credentialPoll = credentialPoll
        let credentialDeadline = credentialDeadline
        Task { @MainActor in
            publisher.close()
            controller?.dispose()
            credentialPoll?.cancel()
            credentialDeadline?.cancel()
            attempt?.release()
        }
    }

    package func start() {
        guard !started, !closed else { return }
        started = true
        controller = StreamReconnectController(
            scheduler: scheduler,
            random: random,
            onRemount: { [weak self] in self?.mount() },
            onSnapshot: { [weak self] in self?.apply($0) },
            onHeal: { [weak self] in self?.prefetchCredentials() }
        )
        prefetchCredentials()
    }

    package func retry() {
        guard started, !closed, status == .unavailable else { return }
        controller?.retry()
    }

    package func setVisible(_ visible: Bool) {
        let hidden = !visible
        guard !closed, self.hidden != hidden else { return }
        self.hidden = hidden
        attempt?.keepAlive?.cancel()
        attempt?.keepAlive = nil
        if !hidden { attempt?.tickKeepAlive() }
    }

    package func handleWake() {
        guard started, !closed else { return }
        if credentialPoll != nil {
            credentialPoll?.cancel(); credentialPoll = nil
            prefetchCredentials()
        } else { controller?.handleWake() }
    }

    package func close() {
        guard !closed else { return }
        publisher.close()
        closed = true
        controller?.dispose()
        releaseAttempt()
        cancelCredentials()
        pendingURL = nil
    }

    @discardableResult package func sendControl(_ data: Data) -> Bool {
        attempt?.send(data, channelID: DataChannels.control.id) ?? false
    }

    @discardableResult package func sendHover(_ data: Data) -> Bool {
        attempt?.send(data, channelID: DataChannels.hover.id) ?? false
    }

    package func openURL(_ url: String) {
        guard !closed else { return }
        if let attempt, attempt.openChannels.contains(DataChannels.control.id) {
            attempt.sendURL(url)
        } else {
            pendingURL = url
        }
    }

    package func screenshot(
        timeout: TimeInterval = 30
    ) async throws -> Data {
        guard let attempt, attempt.socketOpen else { throw StreamError.notConnected }
        return try await attempt.screenshot(timeout: timeout)
    }

    package func startPublish(_ options: PublishOptions) async throws -> PublishState {
        let original = attempt
        return try await publisher.start(options, media: original?.peer as? any PublishMediaTransport,
            ready: original?.socketOpen == true && original?.state == .connected,
            send: { [weak original] object in
                guard let original, original.current, original.socketOpen,
                      let data = try? JSONEncoder().encode(object) else { return false }
                return original.socket?.send(String(decoding: data, as: UTF8.self)) ?? false
            })
    }

    #if DEBUG
        package func requestConfigurationRefresh() {
            guard let attempt else { return }
            attempt.sendMessage(.requestRTCConfiguration(sessionID: attempt.sessionID))
        }
    #endif

    private func apply(_ snapshot: StreamReconnectSnapshot) {
        guard !closed else { return }
        reportError(snapshot)
        switch snapshot.status {
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
        case .reconnecting:
            // Preserve a previously connected peer that could recover before the remount.
            // Other transitions are startup/watchdog failures and must cancel pending setup.
            if status != .connected || attempt == nil {
                releaseAttempt()
            }
            status = .reconnecting(attempt: snapshot.attempt)
        case .unavailable:
            status = .unavailable
            releaseAttempt()
        }
        // Defer credential application until the controller has finished emitting its transition.
        Task { @MainActor [weak self] in self?.applyPendingTarget() }
    }

    /// Failures are the only transitions that raise the attempt count; retries and wakes restart it at zero.
    private func reportError(_ snapshot: StreamReconnectSnapshot) {
        guard snapshot.attempt >= 1,
              snapshot.status == .reconnecting || snapshot.status == .unavailable else { return }
        let reason = pendingReason ?? .unknown
        onError?(StreamConnectionError(
            reason: reason, message: reason.defaultMessage,
            attempt: snapshot.attempt, final: snapshot.status == .unavailable))
    }

    /// Counts one failure and attributes it to the reason that caused it.
    private func countFailure(_ reason: StreamErrorReason, disconnect: Bool = false) {
        pendingReason = reason
        defer { pendingReason = nil }
        if disconnect { controller?.handleDisconnected() } else { controller?.handleFailure() }
    }

    /// Refreshes survive remounts; only disposal or this call's deadline cancels the provider.
    private func prefetchCredentials() {
        guard !closed, credentialTask == nil else { return }
        credentialGeneration += 1
        let generation = credentialGeneration
        let provider = credentials
        credentialDeadline = scheduler.schedule(delayMs: ReconnectPolicy.connectTimeoutMs) { [weak self] in
            guard let self, self.credentialGeneration == generation else { return }
            self.credentialTask?.cancel()
            self.finishCredentials(nil, generation: generation)
        }
        credentialTask = Task { [weak self] in
            let value: StreamCredentials?
            do { value = try await provider() } catch { value = nil }
            guard !Task.isCancelled else { return }
            self?.finishCredentials(value, generation: generation)
        }
    }

    private func finishCredentials(_ value: StreamCredentials?, generation: Int) {
        guard !closed, credentialGeneration == generation else { return }
        credentialGeneration += 1
        credentialTask = nil
        credentialDeadline?.cancel(); credentialDeadline = nil
        if let value {
            let firstTarget = latestTarget == nil
            latestTarget = value
            if firstTarget { mount() } else { applyPendingTarget() }
        } else if latestTarget == nil {
            // Only the initial target discovery polls. A failed refresh keeps the cached target.
            credentialPoll = scheduler.schedule(delayMs: Self.credentialPollIntervalMs) { [weak self] in
                self?.credentialPoll = nil
                self?.prefetchCredentials()
            }
        }
    }

    private func applyPendingTarget() {
        guard !closed, let latestTarget, let activeTarget,
              latestTarget.url != activeTarget.url || (status != .connected && latestTarget.token != activeTarget.token),
              controller?.shouldDeferTargetChange == false else { return }
        mount()
    }

    private func cancelCredentials() {
        credentialGeneration += 1
        credentialPoll?.cancel(); credentialPoll = nil
        credentialDeadline?.cancel(); credentialDeadline = nil
        credentialTask?.cancel(); credentialTask = nil
    }

    private func releaseAttempt() {
        publisher.disconnect()
        onPeerConnectivity?(false)
        let previous = attempt
        attempt = nil
        previous?.release()
    }

    private func mount() {
        guard !closed, let target = latestTarget else { return }
        releaseAttempt()
        activeTarget = target
        warnIfStatic(target)
        let next = Attempt(owner: self, scheduler: scheduler)
        attempt = next
        controller?.attemptMounted(startWatchdog: target.tokenProvider == nil)
        next.open(target)
    }

    private func warnIfStatic(_ target: StreamCredentials) {
        guard !warnedStaticToken, target.tokenProvider == nil,
              target.token?.isEmpty == false || target.url.query?.contains("token=") == true else { return }
        warnedStaticToken = true
        onWarning("Static stream tokens are deprecated: reconnects reuse the same token, which fails for single-use keys. Pass StreamCredentials(url:tokenProvider:) instead.")
    }

    private func fail(_ source: Attempt, reason: StreamErrorReason, rejectedToken: Bool = false) {
        guard attempt === source, !closed else { return }
        releaseAttempt()
        countFailure(reason)
        if rejectedToken { prefetchCredentials() }
    }

    private func diagnostic(_ event: String) {
        #if DEBUG
            onDiagnostic?(event)
        #endif
    }

    @MainActor private final class Attempt {
        weak var owner: StreamSessionEngine?
        let scheduler: any ReconnectScheduler
        let sessionID = UUID().uuidString
        var socket: (any SignallingTransport)?
        var peer: (any PeerTransport)?
        var socketOpen = false
        var wasConnected = false
        var openChannels: Set<Int> = []
        var phase: SignallingPhase = .awaitingRTCConfiguration
        var answered = false
        var candidates: [ServerMessage.Candidate] = []
        var state: PeerConnectionState = .new
        var handshake: (any ScheduledTask)?
        var keepAlive: (any ScheduledTask)?
        var grace: (any ScheduledTask)?
        var frameRequests: [any ScheduledTask] = []
        var tokenTask: Task<Void, Never>?
        var tokenDeadline: (any ScheduledTask)?
        var processing: Task<Void, Never>?
        var messages: [ServerMessage] = []
        struct ScreenshotRequest {
            let continuation: CheckedContinuation<Data, Error>
            let timer: any ScheduledTask
        }
        var screenshots: [String: ScreenshotRequest] = [:]
        var current: Bool { owner?.attempt === self }

        init(owner: StreamSessionEngine, scheduler: any ReconnectScheduler) {
            self.owner = owner
            self.scheduler = scheduler
        }

        deinit {
            let socket = socket
            let peer = peer
            Task { @MainActor in
                socket?.close()
                peer?.close()
            }
        }

        func open(_ credentials: StreamCredentials) {
            guard let provider = credentials.tokenProvider else {
                allocateSocket(credentials)
                return
            }
            guard providerDestinationAllowed(credentials.url) else {
                providerFailed("stream token destination rejected")
                return
            }
            tokenDeadline = scheduler.schedule(delayMs: ReconnectPolicy.providerTimeoutMs) { [weak self] in
                self?.providerFailed("stream token provider timeout")
            }
            // Never run user code on the engine actor or wait for cooperative cancellation.
            tokenTask = Task.detached { [weak self] in
                do {
                    let token = try await provider()
                    guard !Task.isCancelled else { return }
                    await self?.finishToken(token, target: credentials)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.providerFailed("stream token provider failed")
                }
            }
        }

        func finishToken(_ token: String, target: StreamCredentials) {
            guard current else { return }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                providerFailed("stream token provider returned blank")
                return
            }
            tokenDeadline?.cancel()
            tokenDeadline = nil
            tokenTask = nil
            allocateSocket(StreamCredentials(url: target.url, token: token))
        }

        func providerFailed(_ diagnostic: String) {
            guard current else { return }
            owner?.diagnostic(diagnostic)
            fail(.credentialsUnavailable)
        }

        func allocateSocket(_ credentials: StreamCredentials) {
            guard current, let owner else { return }
            if owner.activeTarget?.tokenProvider != nil {
                owner.controller?.attemptMounted()
            }
            owner.onAttemptStarted?()
            guard current else { return }
            let socket = owner.signalling()
            self.socket = socket
            socket.onEvent = { [weak self] in self?.socketEvent($0) }
            handshake = scheduler.schedule(delayMs: SignallingTiming.wsOpenTimeoutMs) { [weak self] in
                self?.fail(.connectionRefused)
            }
            tickKeepAlive()
            do { try socket.open(credentials) } catch { fail(.connectionRefused) }
        }

        func release() {
            tokenDeadline?.cancel()
            tokenDeadline = nil
            tokenTask?.cancel()
            tokenTask = nil
            socketOpen = false
            openChannels.removeAll()
            handshake?.cancel()
            keepAlive?.cancel()
            endGrace()
            frameRequests.forEach { $0.cancel() }
            frameRequests.removeAll()
            processing?.cancel()
            processing = nil
            messages.removeAll()
            candidates.removeAll()
            for id in Array(screenshots.keys) {
                finishScreenshot(id, .failure(StreamError.disconnected))
            }
            socket?.onEvent = nil
            peer?.onEvent = nil
            socket?.close()
            peer?.close()
            socket = nil
            peer = nil
        }

        func fail(_ reason: StreamErrorReason, rejectedToken: Bool = false) {
            guard current else { return }
            owner?.fail(self, reason: reason, rejectedToken: rejectedToken)
        }

        @discardableResult func sendMessage(_ message: ClientMessage) -> Bool {
            guard current, socketOpen, let text = try? message.toJSON() else { return false }
            return socket?.send(text) ?? false
        }

        func send(_ data: Data, channelID: Int) -> Bool {
            guard current, openChannels.contains(channelID) else { return false }
            return peer?.send(data, channelID: channelID) ?? false
        }

        func sendURL(_ url: String) {
            sendMessage(.openURL(.create(suppliedURL: url, sessionID: sessionID)))
        }

        func tickKeepAlive() {
            keepAlive?.cancel()
            guard owner?.hidden == false else { return }
            keepAlive = scheduler.schedule(delayMs: SignallingTiming.keepAliveIntervalMs) { [weak self] in
                guard let self, self.current else { return }
                self.sendMessage(.keepAlive(sessionID: self.sessionID))
                self.tickKeepAlive()
            }
        }

        func socketEvent(_ event: SignallingEvent) {
            guard current else { return }
            switch event {
            case .opened:
                socketOpen = true
                handshake?.cancel()
                handshake = scheduler.schedule(delayMs: SignallingTiming.rtcConfigTimeoutMs) { [weak self] in
                    self?.fail(.unknown)
                }
                sendMessage(.requestRTCConfiguration(sessionID: sessionID))
            case .closed:
                fail(socketOpen ? .disconnected : .connectionRefused)
            case .failed(let status):
                if let status, HTTPStatus.isDeviceUnavailable(status) {
                    owner?.diagnostic("device unavailable http=\(status)")
                }
                fail(reason(forFailure: status), rejectedToken: status.map(HTTPStatus.isTokenRejected) ?? false)
            case .message(let text):
                owner?.publisher.receive(text)
                switch ServerMessage.parse(text, phase: phase) {
                case .ignored:
                    break
                case .startupFailure:
                    fail(.unknown)
                case .message(let message):
                    if case .rtcConfiguration = message, phase == .awaitingRTCConfiguration {
                        phase = .established
                        handshake?.cancel()
                    }
                    messages.append(message)
                    drainMessages()
                }
            }
        }

        func drainMessages() {
            guard processing == nil else { return }
            processing = Task { [weak self] in
                guard let self else { return }
                while self.current, !Task.isCancelled, !self.messages.isEmpty {
                    await self.handle(self.messages.removeFirst())
                }
                self.processing = nil
            }
        }

        func handle(_ message: ServerMessage) async {
            guard current else { return }
            switch message {
            case .rtcConfiguration(let config):
                if let peer { await restartIce(config, peer: peer) } else { await createPeer(config) }
            case .answer(let answer):
                guard let peer else { return }
                do { try await peer.setRemoteAnswer(answer.sdp) } catch { return }
                guard current else { return }
                owner?.diagnostic("answer applied")
                answered = true
                let buffered = candidates
                candidates.removeAll()
                for candidate in buffered {
                    guard current else { return }
                    try? await peer.addRemoteCandidate(candidate)
                }
            case .candidate(let candidate):
                guard let peer else { return }
                if answered {
                    try? await peer.addRemoteCandidate(candidate)
                } else {
                    candidates.append(candidate)
                }
            case .screenshot(let response):
                finishScreenshot(response.id, Result { try decodeDataURI(response.dataURI) })
            case .screenshotError(let response):
                finishScreenshot(response.id, .failure(StreamError.screenshotFailed))
            }
        }

        func createPeer(_ config: ServerMessage.RTCConfiguration) async {
            guard let peer = owner?.peers() else { return }
            self.peer = peer
            peer.onEvent = { [weak self] in self?.peerEvent($0) }
            do {
                try peer.configure(config, channels: [DataChannels.control, DataChannels.hover])
                let sdp = try await peer.createOffer(iceRestart: false)
                guard current else { return }
                sendMessage(.offer(sdp: sdp, sessionID: sessionID))
            } catch { fail(.unknown) }
        }

        func reason(forFailure status: Int?) -> StreamErrorReason {
            switch status {
            case 401: .tokenRejected
            case .some: .connectionRefused
            case nil: socketOpen ? .disconnected : .connectionRefused
            }
        }

        func restartIce(_ config: ServerMessage.RTCConfiguration, peer: any PeerTransport) async {
            guard let servers = config.iceServers, peer.setIceServers(servers) else { return }
            owner?.diagnostic("configuration refreshed")
            endGrace()
            grace = scheduler.schedule(delayMs: SignallingTiming.iceRestartGraceMs) { [weak self] in
                guard let self, self.current else { return }
                self.endGrace()
                if self.state != .connected {
                    self.owner?.publisher.disconnect()
                    self.owner?.countFailure(.disconnected, disconnect: true)
                }
            }
            do {
                let sdp = try await peer.createOffer(iceRestart: true)
                guard current else { return }
                answered = false
                candidates.removeAll()
                sendMessage(.offer(sdp: sdp, sessionID: sessionID))
                owner?.diagnostic("restart offer sent")
            } catch {
                endGrace()
                if current, state != .connected {
                    owner?.publisher.disconnect()
                    owner?.countFailure(.disconnected, disconnect: true)
                }
            }
        }

        func endGrace() {
            grace?.cancel()
            grace = nil
        }

        func peerEvent(_ event: PeerEvent) {
            guard current else { return }
            switch event {
            case .candidate(let sdp, let mid, let index):
                sendMessage(
                    .candidate(candidate: sdp, sdpMid: mid, sdpMLineIndex: index, sessionID: sessionID))
            case .state(let state):
                owner?.onPeerConnectivity?(state == .connected)
                if state == .disconnected && grace == nil { owner?.publisher.disconnect() }
                self.state = state
                if state == .failed || state == .closed {
                    fail(wasConnected ? .disconnected : .unknown)
                } else if state == .connected {
                    wasConnected = true
                    endGrace()
                    owner?.controller?.handleConnected()
                } else if grace == nil {
                    owner?.countFailure(.disconnected, disconnect: true)
                }
            case .channel(let id, let open):
                let wasOpen = openChannels.contains(id)
                if open { openChannels.insert(id) } else { openChannels.remove(id) }
                guard id == DataChannels.control.id, open, !wasOpen else { return }
                frameRequests.forEach { $0.cancel() }
                frameRequests.removeAll()
                for index in 0..<SignallingTiming.requestFrameCount {
                    frameRequests.append(
                        scheduler.schedule(
                            delayMs: index * SignallingTiming.requestFrameIntervalMs
                        ) { [weak self] in
                            guard let self else { return }
                            self.sendMessage(.requestFrame(sessionID: self.sessionID))
                        })
                }
                if let url = owner?.pendingURL {
                    owner?.pendingURL = nil
                    sendURL(url)
                }
            }
        }

        func screenshot(timeout: TimeInterval) async throws -> Data {
            let id = UUID().uuidString
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard current, socketOpen else {
                        continuation.resume(throwing: StreamError.disconnected)
                        return
                    }
                    let maximumSeconds = TimeInterval(24 * 60 * 60)
                    let seconds =
                        timeout.isNaN
                        ? TimeInterval(SignallingTiming.screenshotTimeoutMs) / 1000
                        : min(maximumSeconds, max(0, timeout))
                    let timer = scheduler.schedule(delayMs: Int(seconds * 1000)) { [weak self] in
                        self?.finishScreenshot(id, .failure(StreamError.screenshotTimeout))
                    }
                    screenshots[id] = ScreenshotRequest(continuation: continuation, timer: timer)
                    if !sendMessage(.screenshot(id: id)) {
                        finishScreenshot(id, .failure(StreamError.disconnected))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finishScreenshot(id, .failure(CancellationError()))
                }
            }
        }

        func finishScreenshot(_ id: String, _ result: Result<Data, Error>) {
            guard let request = screenshots.removeValue(forKey: id) else { return }
            request.timer.cancel()
            request.continuation.resume(with: result)
        }
    }
}

private enum HTTPStatus {
    static func isTokenRejected(_ status: Int) -> Bool { status == 401 || status == 403 }
    static func isDeviceUnavailable(_ status: Int) -> Bool { status == 401 || status == 404 }
}

private func decodeDataURI(_ uri: String) throws -> Data {
    let parts = uri.components(separatedBy: ";base64,")
    guard parts.count == 2, parts[0].hasPrefix("data:"), let bytes = Data(base64Encoded: parts[1]) else {
        throw StreamError.screenshotFailed
    }
    return bytes
}

// Foundation parses the authority; only exact loopback hosts permit plaintext development sockets.
private func providerDestinationAllowed(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = parts.host?.lowercased(), !host.isEmpty else { return false }
    if parts.scheme?.lowercased() == "wss" { return true }
    let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    return parts.scheme?.lowercased() == "ws" && loopback
}
