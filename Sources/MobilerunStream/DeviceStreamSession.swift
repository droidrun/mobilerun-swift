// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import Foundation
    import Combine
    import MobilerunProtocol
    import MobilerunStreamCore
    @preconcurrency import LiveKitWebRTC

    /// A live stream with automatic recovery and no app lifecycle observers.
    /// All sessions share one process-wide peer factory. close releases the session's resources.
    @MainActor public final class DeviceStreamSession: ObservableObject {
        @Published public private(set) var status: StreamStatus = .connecting
        @Published private(set) var isClosed = false
        @Published public private(set) var videoSize: VideoSize?
        /// Latest failed attempt; cleared once the stream connects again.
        @Published public private(set) var lastError: StreamConnectionError?
        /// Called on the main actor for every failed attempt with its reason; `final` means retries stopped.
        public var onError: (@MainActor (StreamConnectionError) -> Void)?
        /// Latest inbound-video sample; nil unless connected, visible and subscribed.
        public var stats: StreamStats? { statistics.value }
        /// Samples native reports once per second. Completes when the session closes.
        public var statsPublisher: AnyPublisher<StreamStats?, Never> { statistics.publisher }
        private let statistics = StreamStatsObservation()
        // Only the package's native renderer consumes tracks; apps use DeviceStreamView.
        @Published package private(set) var videoTrack: LKRTCVideoTrack?
        private weak var signalling: URLSessionSignalling?
        private weak var peer: WebRTCPeer?
        private var muted: Bool
        private var hidden = false
        private var peerConnected = false
        private var attemptStartedAt = ProcessInfo.processInfo.systemUptime
        private var sampler: StreamStatsSampler?
        private var engine: StreamSessionEngine!

        #if DEBUG
            var onDiagnostic: (@MainActor (String) -> Void)? {
                get { engine.onDiagnostic }
                set { engine.onDiagnostic = newValue }
            }
        #endif

        public init(credentials: @escaping StreamCredentialsProvider, config: StreamConfig = StreamConfig()) {
            muted = config.muted
            engine = StreamSessionEngine(
                credentials: credentials,
                scheduler: MainActorScheduler(),
                signalling: { [weak self] in
                    let socket = URLSessionSignalling()
                    #if DEBUG
                        socket.onDiagnostic = { [weak self] in self?.onDiagnostic?($0) }
                    #endif
                    self?.signalling = socket
                    return socket
                },
                peers: { [weak self] in
                    var currentConfig = config
                    currentConfig.muted = self?.muted ?? config.muted
                    let peer = WebRTCPeer(
                        config: currentConfig, startedAt: self?.attemptStartedAt ?? ProcessInfo.processInfo.systemUptime,
                        onTrack: { [weak self] track in
                            self?.videoTrack = track
                            if track == nil { self?.videoSize = nil }
                        },
                        onSize: { [weak self] in self?.videoSize = $0 }
                    )
                    #if DEBUG
                        peer.onDiagnostic = { [weak self] in self?.onDiagnostic?($0) }
                    #endif
                    self?.peer = peer
                    return peer
                }
            )
            bindSession(scheduler: MainActorScheduler(), request: { [weak self] completion in
                guard let peer = self?.peer else { completion([], nil); return }
                peer.statistics(completion)
            })
        }

        private func bindSession(
            scheduler: any ReconnectScheduler,
            request: @escaping @MainActor (@escaping StreamStatsSampler.Completion) -> Void
        ) {
            sampler = StreamStatsSampler(scheduler: scheduler, request: { [weak self] completion in
                guard self?.canSampleStats == true else { completion([], nil); return }
                request(completion)
            }, publish: { [weak self] sample in
                self?.statistics.send(sample)
            })
            statistics.onObserversChanged = { [weak self] in self?.updateSampling() }
            engine.onAttemptStarted = { [weak self] in
                self?.attemptStartedAt = ProcessInfo.processInfo.systemUptime
            }
            engine.onPeerConnectivity = { [weak self] connected in
                self?.peerConnected = connected
                self?.updateSampling()
            }
            engine.onError = { [weak self] error in
                self?.lastError = error
                self?.onError?(error)
            }
            engine.onStatus = { [weak self] status in
                guard let self else { return }
                self.status = status
                if status == .connected { self.lastError = nil }
                self.updateSampling()
            }
        }

        deinit {
            let engine = engine
            let sampler = sampler
            let statistics = statistics
            Task { @MainActor in
                sampler?.setActive(false)
                statistics.finish()
                engine?.close()
            }
        }

        private var canSampleStats: Bool { !isClosed && status == .connected && peerConnected && !hidden && statistics.isObserved }

        private func updateSampling() { sampler?.setActive(canSampleStats) }

        /// Idempotent. A closed session cannot be restarted.
        public func start() { engine.start() }
        /// Starts a fresh cycle after the retry budget is exhausted.
        public func retry() { engine.retry() }
        public func close() {
            guard !isClosed else { return }
            engine.close()
            isClosed = true
            updateSampling()
            statistics.finish()
        }
        /// Suspend keep-alives while not visible. The default UI manages this automatically.
        public func setVisible(_ visible: Bool) {
            self.hidden = !visible
            updateSampling()
            engine.setVisible(visible)
        }
        /// Foreground/network recovery skips backoff or restarts an unavailable session.
        public func handleWake() { engine.handleWake() }
        /// Updates received audio and the shared manual-audio gate. Muted sessions never activate audio.
        public func setMuted(_ muted: Bool) {
            self.muted = muted
            peer?.setMuted(muted)
        }
        /// Drops bytes and returns false unless the reliable control channel is open.
        @discardableResult package func sendControl(_ data: Data) -> Bool { engine.sendControl(data) }
        /// Uses only the unreliable hover channel; never falls back to control.
        @discardableResult package func sendHover(_ data: Data) -> Bool { engine.sendHover(data) }
        public func openURL(_ url: String) { engine.openURL(url) }
        public func screenshot(
            timeout: TimeInterval = 30
        ) async throws -> Data {
            try await engine.screenshot(timeout: timeout)
        }

        #if DEBUG
            /// Keeps transport recording tests on the same session-to-engine path as the native adapter.
            init(engine: StreamSessionEngine, videoSize: VideoSize,
                 statsScheduler: any ReconnectScheduler = MainActorScheduler(),
                 statistics: @escaping @MainActor (@escaping StreamStatsSampler.Completion) -> Void = { $0([], nil) }) {
                muted = true
                self.engine = engine
                self.videoSize = videoSize
                bindSession(scheduler: statsScheduler, request: statistics)
            }

            func presentForTesting(_ status: StreamStatus) { self.status = status }

            var transportsReleasedForTesting: Bool { peer == nil && signalling == nil }

            func forceSignallingClose() { signalling?.forceClose() }
            func requestConfigurationRefresh() { engine.requestConfigurationRefresh() }
        #endif
    }
#endif
