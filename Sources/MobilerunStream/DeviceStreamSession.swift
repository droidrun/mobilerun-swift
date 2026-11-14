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
        @Published public private(set) var videoSize: VideoSize?
        // Only the package's native renderer consumes tracks; apps use DeviceStreamView.
        @Published package private(set) var videoTrack: LKRTCVideoTrack?
        private weak var signalling: URLSessionSignalling?
        private weak var peer: WebRTCPeer?
        private var muted: Bool
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
                    self?.signalling = socket
                    return socket
                },
                peers: { [weak self] in
                    var currentConfig = config
                    currentConfig.muted = self?.muted ?? config.muted
                    let peer = WebRTCPeer(
                        config: currentConfig,
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
            engine.onStatus = { [weak self] in self?.status = $0 }
        }

        deinit {
            let engine = engine
            Task { @MainActor in engine?.close() }
        }

        /// Idempotent. A closed session cannot be restarted.
        public func start() { engine.start() }
        /// Starts a fresh cycle after the retry budget is exhausted.
        public func retry() { engine.retry() }
        public func close() { engine.close() }
        /// Suspend keep-alives while hidden. The default UI manages this automatically.
        public func setHidden(_ hidden: Bool) { engine.setHidden(hidden) }
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
            timeout: TimeInterval = TimeInterval(SignallingTiming.screenshotTimeoutMs) / 1000
        ) async throws -> Data {
            try await engine.screenshot(timeout: timeout)
        }

        #if DEBUG
            /// Keeps transport recording tests on the same session-to-engine path as the native adapter.
            init(engine: StreamSessionEngine, videoSize: VideoSize) {
                muted = true
                self.engine = engine
                self.videoSize = videoSize
                engine.onStatus = { [weak self] in self?.status = $0 }
            }

            func presentForTesting(_ status: StreamStatus) { self.status = status }

            func forceSignallingClose() { signalling?.forceClose() }
            func requestConfigurationRefresh() { engine.requestConfigurationRefresh() }
        #endif
    }
#endif
