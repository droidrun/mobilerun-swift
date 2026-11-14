// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// Transport-independent session, serialized on the main actor. Call close before releasing it.
/// Each attempt owns its timers, messages and peer; callbacks from replaced attempts are ignored.
@MainActor public final class StreamSessionEngine {
    public private(set) var status: StreamStatus = .connecting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    @_spi(Testing) public var onDiagnostic: (@MainActor (String) -> Void)?
    public var onStatus: (@MainActor (StreamStatus) -> Void)?
    /// Fired before releasing a peer so a renderer can detach its track.
    public var onReleaseMedia: (@MainActor () -> Void)?
    private let credentials: StreamCredentialsProvider
    private let signalling: @MainActor () -> any SignallingTransport
    private let peers: @MainActor () -> any PeerTransport
    private let scheduler: any ReconnectScheduler
    private let random: () -> Double
    private var started = false
    private var closed = false
    private var attempt: Attempt?
    private var mountTask: Task<Void, Never>?
    private var credentialTask: Task<StreamCredentials?, Error>?
    private var epoch = 0
    private var pendingURL: String?
    private lazy var controller = StreamReconnectController(
        scheduler: scheduler, random: random,
        onRemount: { [weak self] in self?.mount() },
        onSnapshot: { [weak self] snapshot in
            guard let self, !self.closed else { return }
            switch snapshot.status {
            case .connecting: self.status = .connecting
            case .connected:
                // A peer may recover before the scheduled remount. Discard that cycle's
                // unused prefetch so a later heal always asks for fresh credentials.
                self.credentialTask?.cancel(); self.credentialTask = nil
                self.status = .connected
            case .reconnecting:
                self.status = .reconnecting(attempt: snapshot.attempt)
                if self.attempt == nil { self.mountTask?.cancel(); self.mountTask = nil }
            case .unavailable: self.status = .unavailable; self.releaseAttempt()
            }
        },
        onHeal: { [weak self] in self?.refreshCredentials() }
    )

    public init(credentials: @escaping StreamCredentialsProvider,
                scheduler: any ReconnectScheduler,
                random: @escaping () -> Double = { Double.random(in: 0..<1) },
                signalling: @escaping @MainActor () -> any SignallingTransport,
                peers: @escaping @MainActor () -> any PeerTransport) {
        self.credentials = credentials; self.scheduler = scheduler; self.random = random
        self.signalling = signalling; self.peers = peers
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        mount()
    }
    public func retry() { guard started, !closed else { return }; controller.retry() }
    public func close() {
        guard !closed else { return }
        closed = true; epoch += 1
        controller.dispose()
        releaseAttempt()
        credentialTask?.cancel(); credentialTask = nil
        pendingURL = nil
        status = .closed
    }
    @discardableResult public func sendControl(_ data: Data) -> Bool {
        attempt?.send(data, channelID: DataChannels.control.id) ?? false
    }
    @discardableResult public func sendHover(_ data: Data) -> Bool {
        attempt?.send(data, channelID: DataChannels.hover.id) ?? false
    }
    public func openURL(_ url: String) {
        guard !closed else { return }
        if let attempt, attempt.controlOpen { attempt.sendURL(url) }
        else { pendingURL = url }
    }
    public func screenshot(timeout: TimeInterval = 30) async throws -> Data {
        guard let attempt, attempt.socketOpen else { throw StreamError.notConnected }
        return try await attempt.screenshot(timeout: timeout)
    }

    /// Testing hook: request fresh server configuration and exercise the normal receive path.
    @_spi(Testing) public func requestConfigurationRefresh() {
        guard let attempt else { return }
        attempt.sendMessage(.requestRTCConfiguration(sessionID: attempt.sessionID))
    }

    private func refreshCredentials() {
        guard !closed, credentialTask == nil else { return }
        let provider = credentials
        credentialTask = Task { try await provider() }
    }
    private func releaseAttempt() {
        mountTask?.cancel(); mountTask = nil
        attempt?.release(); attempt = nil
        onReleaseMedia?()
    }
    private func mount() {
        guard !closed else { return }
        epoch += 1
        let captured = epoch
        releaseAttempt()
        controller.attemptMounted()
        refreshCredentials()
        let request = credentialTask!
        mountTask = Task { [weak self] in
            do {
                let value = try await request.value
                guard let self, !self.closed, self.epoch == captured, !Task.isCancelled else { return }
                self.credentialTask = nil
                guard let value else { self.controller.handleFailure(); return }
                let attempt = Attempt(owner: self, scheduler: self.scheduler)
                self.attempt = attempt
                attempt.open(value)
            } catch {
                guard let self, !self.closed, self.epoch == captured, !Task.isCancelled else { return }
                self.credentialTask = nil
                self.controller.handleFailure()
            }
        }
    }
    private func fail(_ source: Attempt, rejectedToken: Bool = false) {
        guard attempt === source, !closed else { return }
        source.release()
        onReleaseMedia?()
        controller.handleFailure()
        if rejectedToken { refreshCredentials() }
    }

    @MainActor private final class Attempt {
        weak var owner: StreamSessionEngine?
        let scheduler: any ReconnectScheduler
        let sessionID = UUID().uuidString
        var socket: (any SignallingTransport)?
        var peer: (any PeerTransport)?
        var released = false
        var socketOpen = false
        var controlOpen = false
        var hoverOpen = false
        var phase: SignallingPhase = .awaitingRTCConfiguration
        var answered = false
        var candidates: [ServerMessage.Candidate] = []
        var state: PeerConnectionState = .new
        var graceActive = false
        var handshake: (any ScheduledTask)?
        var keepAlive: (any ScheduledTask)?
        var grace: (any ScheduledTask)?
        var frameRequests: [any ScheduledTask] = []
        var processing: Task<Void, Never>?
        var messages: [ServerMessage] = []
        struct ScreenshotRequest {
            let continuation: CheckedContinuation<Data, Error>
            let timer: any ScheduledTask
        }
        var screenshots: [String: ScreenshotRequest] = [:]
        var current: Bool { !released && owner?.attempt === self }

        init(owner: StreamSessionEngine, scheduler: any ReconnectScheduler) {
            self.owner = owner; self.scheduler = scheduler
        }
        func open(_ credentials: StreamCredentials) {
            guard let owner else { return }
            let socket = owner.signalling()
            self.socket = socket
            socket.onEvent = { [weak self] event in self?.socketEvent(event) }
            handshake = scheduler.schedule(delayMs: SignallingTiming.wsOpenTimeoutMs) { [weak self] in self?.fail() }
            tickKeepAlive()
            do { try socket.open(credentials) } catch { fail() }
        }
        func release() {
            guard !released else { return }
            released = true; socketOpen = false; controlOpen = false; hoverOpen = false
            handshake?.cancel(); keepAlive?.cancel(); grace?.cancel()
            frameRequests.forEach { $0.cancel() }; frameRequests.removeAll()
            processing?.cancel(); processing = nil; messages.removeAll(); candidates.removeAll()
            let pending = screenshots; screenshots.removeAll()
            for request in pending.values {
                request.timer.cancel(); request.continuation.resume(throwing: StreamError.disconnected)
            }
            socket?.onEvent = nil; peer?.onEvent = nil
            socket?.close(); peer?.close(); socket = nil; peer = nil
        }
        func fail(rejectedToken: Bool = false) {
            guard current else { return }
            owner?.fail(self, rejectedToken: rejectedToken)
        }
        @discardableResult func sendMessage(_ message: ClientMessage) -> Bool {
            guard current, socketOpen, let text = try? message.toJSON() else { return false }
            return socket?.send(text) ?? false
        }
        func send(_ data: Data, channelID: Int) -> Bool {
            guard current, channelID == DataChannels.control.id ? controlOpen : hoverOpen else { return false }
            return peer?.send(data, channelID: channelID) ?? false
        }
        func sendURL(_ url: String) {
            sendMessage(.openURL(.create(suppliedURL: url, sessionID: sessionID)))
        }
        func tickKeepAlive() {
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
                socketOpen = true; handshake?.cancel()
                handshake = scheduler.schedule(delayMs: SignallingTiming.rtcConfigTimeoutMs) { [weak self] in self?.fail() }
                sendMessage(.requestRTCConfiguration(sessionID: sessionID))
            case .closed: fail()
            case .failed(let code):
                if code == 401 || code == 404 { owner?.onDiagnostic?("device unavailable http=\(code!)") }
                fail(rejectedToken: code == 401 || code == 403)
            case .message(let text):
                switch ServerMessage.parse(text, phase: phase) {
                case .ignored: break
                case .startupFailure: fail()
                case .message(let message):
                    // Change phase synchronously so a second configuration queues as a refresh.
                    if case .rtcConfiguration = message, phase == .awaitingRTCConfiguration {
                        phase = .established; handshake?.cancel()
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
                    let next = self.messages.removeFirst()
                    await self.handle(next)
                }
                self.processing = nil
            }
        }
        func handle(_ message: ServerMessage) async {
            guard current else { return }
            switch message {
            case .rtcConfiguration(let config):
                if let peer {
                    guard let servers = config.iceServers, peer.setIceServers(servers) else { return }
                    owner?.onDiagnostic?("configuration refreshed")
                    graceActive = true
                    grace?.cancel()
                    grace = scheduler.schedule(delayMs: SignallingTiming.iceRestartGraceMs) { [weak self] in
                        guard let self, self.current else { return }
                        self.graceActive = false
                        if self.state != .connected { self.owner?.controller.handleDisconnected() }
                    }
                    do {
                        let sdp = try await peer.createOffer(iceRestart: true)
                        guard current else { return }
                        answered = false; candidates.removeAll()
                        sendMessage(.offer(sdp: sdp, sessionID: sessionID))
                        owner?.onDiagnostic?("restart offer sent")
                    } catch {
                        graceActive = false; grace?.cancel()
                        if current, state != .connected { owner?.controller.handleDisconnected() }
                    }
                } else {
                    guard let owner else { return }
                    let peer = owner.peers(); self.peer = peer
                    peer.onEvent = { [weak self] event in self?.peerEvent(event) }
                    do {
                        try peer.configure(config, channels: [DataChannels.control, DataChannels.hover])
                        let sdp = try await peer.createOffer(iceRestart: false)
                        guard current else { return }
                        sendMessage(.offer(sdp: sdp, sessionID: sessionID))
                    } catch { fail() }
                }
            case .answer(let answer):
                guard let peer else { return }
                do { try await peer.setRemoteAnswer(answer.sdp) } catch { return }
                guard current else { return }
                owner?.onDiagnostic?("answer applied")
                answered = true
                let buffered = candidates; candidates.removeAll()
                for candidate in buffered {
                    guard current else { return }
                    try? await peer.addRemoteCandidate(candidate)
                }
            case .candidate(let candidate):
                guard let peer else { return }
                if answered { try? await peer.addRemoteCandidate(candidate) }
                else { candidates.append(candidate) }
            case .screenshot(let response):
                guard let request = screenshots.removeValue(forKey: response.id) else { return }
                request.timer.cancel()
                let parts = response.dataURI.components(separatedBy: ";base64,")
                if parts.count == 2, parts[0].hasPrefix("data:"), let bytes = Data(base64Encoded: parts[1]) {
                    request.continuation.resume(returning: bytes)
                } else { request.continuation.resume(throwing: StreamError.screenshotFailed) }
            case .screenshotError(let response):
                guard let request = screenshots.removeValue(forKey: response.id) else { return }
                request.timer.cancel(); request.continuation.resume(throwing: StreamError.screenshotFailed)
            }
        }
        func peerEvent(_ event: PeerEvent) {
            guard current else { return }
            switch event {
            case .candidate(let sdp, let mid, let index):
                sendMessage(.candidate(candidate: sdp, sdpMid: mid, sdpMLineIndex: index, sessionID: sessionID))
            case .state(let state):
                self.state = state
                if state == .failed || state == .closed { fail(); return }
                if state == .connected {
                    graceActive = false; grace?.cancel()
                    owner?.controller.handleConnected()
                } else if !graceActive { owner?.controller.handleDisconnected() }
            case .channel(let id, let open):
                if id == DataChannels.hover.id { hoverOpen = open }
                guard id == DataChannels.control.id else { return }
                let wasOpen = controlOpen; controlOpen = open
                guard open, !wasOpen else { return }
                frameRequests.forEach { $0.cancel() }; frameRequests.removeAll()
                for index in 0..<SignallingTiming.requestFrameCount {
                    frameRequests.append(scheduler.schedule(delayMs: index * SignallingTiming.requestFrameIntervalMs) { [weak self] in
                        guard let self else { return }
                        self.sendMessage(.requestFrame(sessionID: self.sessionID))
                    })
                }
                if let url = owner?.pendingURL { owner?.pendingURL = nil; sendURL(url) }
            }
        }
        func screenshot(timeout: TimeInterval) async throws -> Data {
            let id = UUID().uuidString
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard current, socketOpen else { continuation.resume(throwing: StreamError.disconnected); return }
                    let milliseconds = timeout.isFinite ? max(0, min(timeout * 1000, Double(Int.max / 2))) : 30_000
                    let timer = scheduler.schedule(delayMs: Int(milliseconds)) { [weak self] in
                        self?.finishScreenshot(id, error: StreamError.screenshotTimeout)
                    }
                    screenshots[id] = ScreenshotRequest(continuation: continuation, timer: timer)
                    if !sendMessage(.screenshot(id: id)) { finishScreenshot(id, error: StreamError.disconnected) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishScreenshot(id, error: CancellationError()) }
            }
        }
        func finishScreenshot(_ id: String, error: any Error) {
            guard let request = screenshots.removeValue(forKey: id) else { return }
            request.timer.cancel(); request.continuation.resume(throwing: error)
        }
    }
}
