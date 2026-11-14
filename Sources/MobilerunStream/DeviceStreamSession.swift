// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

@_spi(Testing) @_exported import MobilerunStreamCore
@_exported import MobilerunProtocol

#if os(iOS)
import Foundation
import Combine
@preconcurrency import LiveKitWebRTC

/// A live stream with automatic recovery. Call start to connect and close to release it.
/// No app lifecycle observers are installed: the host decides the session's lifetime.
/// All sessions share one process-wide peer connection factory. Closing releases the session's
/// socket, channels, tracks and peer, while the factory remains available for other sessions.
@MainActor public final class DeviceStreamSession: ObservableObject {
    @Published public private(set) var status: StreamStatus = .connecting
    @Published public private(set) var videoSize: VideoSize?
    /// Attach your renderer to the latest track, detaching from the old track on replacement.
    @Published public private(set) var videoTrack: LKRTCVideoTrack?
    private weak var signalling: URLSessionSignalling?
    @_spi(Testing) public var onDiagnostic: (@MainActor (String) -> Void)? {
        get { engine.onDiagnostic }
        set { engine.onDiagnostic = newValue }
    }
    private var engine: StreamSessionEngine!

    public init(credentials: @escaping StreamCredentialsProvider, config: StreamConfig = StreamConfig()) {
        engine = StreamSessionEngine(credentials: credentials, scheduler: MainActorScheduler(),
            signalling: { [weak self] in
                let socket = URLSessionSignalling(); self?.signalling = socket; return socket
            },
            peers: { [weak self] in
                WebRTCPeer(config: config, onTrack: { [weak self] in self?.videoTrack = $0 },
                           onSize: { [weak self] size in
                               if self?.videoSize != size { self?.videoSize = size }
                           })
            })
        engine.onStatus = { [weak self] in self?.status = $0 }
        engine.onReleaseMedia = { [weak self] in self?.videoTrack = nil; self?.videoSize = nil }
    }
    /// Idempotent. A closed session cannot be restarted.
    public func start() { engine.start() }
    /// Starts a fresh cycle after the retry budget is exhausted.
    public func retry() { engine.retry() }
    public func close() { engine.close() }
    /// Drops bytes and returns false unless the reliable control channel is open.
    @discardableResult public func sendControl(_ data: Data) -> Bool { engine.sendControl(data) }
    /// Uses only the unreliable hover channel; never falls back to control.
    @discardableResult public func sendHover(_ data: Data) -> Bool { engine.sendHover(data) }
    public func openURL(_ url: String) { engine.openURL(url) }
    public func screenshot(timeout: TimeInterval = 30) async throws -> Data { try await engine.screenshot(timeout: timeout) }

    @_spi(Testing) public func forceSignallingClose() { signalling?.forceClose() }
    @_spi(Testing) public func requestConfigurationRefresh() { engine.requestConfigurationRefresh() }
}
#endif
