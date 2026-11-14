// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
@preconcurrency import LiveKitWebRTC
import MobilerunProtocol
import MobilerunStreamCore

@MainActor final class WebRTCPeer: NSObject, PeerTransport {
    // Factory creation and all session operations are main-actor serialized. Delegate callbacks
    // cross back explicitly; native objects never escape through the pure transport boundary.
    private static let factory = LKRTCPeerConnectionFactory(
        encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
    var onEvent: (@MainActor (PeerEvent) -> Void)?
    private let config: StreamConfig
    private let onTrack: @MainActor (LKRTCVideoTrack?) -> Void
    private let onSize: @MainActor (VideoSize) -> Void
    private var peer: LKRTCPeerConnection?
    private var channels: [Int: LKRTCDataChannel] = [:]
    private var video: LKRTCVideoTrack?
    private var frameObserver: FrameObserver?
    private var closed = false

    init(config: StreamConfig, onTrack: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
         onSize: @escaping @MainActor (VideoSize) -> Void) {
        self.config = config; self.onTrack = onTrack; self.onSize = onSize
    }
    func configure(_ configuration: ServerMessage.RTCConfiguration, channels: [DataChannelSpec]) throws {
        let native = LKRTCConfiguration()
        native.sdpSemantics = .unifiedPlan
        if let object = configuration.configuration, object["iceServers"] != nil, configuration.iceServers == nil {
            throw StreamError.negotiationFailed
        }
        native.iceServers = iceServers(configuration.iceServers ?? [])
        if configuration.configuration?["iceTransportPolicy"] == .string("relay") { native.iceTransportPolicy = .relay }
        guard let peer = Self.factory.peerConnection(with: native,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw StreamError.negotiationFailed
        }
        self.peer = peer
        let recv = LKRTCRtpTransceiverInit(); recv.direction = .recvOnly
        guard peer.addTransceiver(of: .audio, init: recv) != nil,
              let video = peer.addTransceiver(of: .video, init: recv) else { throw StreamError.negotiationFailed }
        let codecs = Self.factory.rtpReceiverCapabilities(forKind: "video").codecs
        let hasHEVC = codecs.contains { ["h265", "hevc"].contains($0.name.lowercased()) }
        if config.videoCodec == .h264Only || !hasHEVC {
            let h264 = codecs.filter { $0.name.lowercased() == "h264" }
            guard !h264.isEmpty else { throw StreamError.negotiationFailed }
            try video.setCodecPreferences(h264, error: ())
        }
        else {
            func priority(_ name: String) -> Int {
                switch name.lowercased() {
                case "vp9": 1
                case "h265", "hevc": 2
                case "h264", "avc": 3
                default: 4
                }
            }
            let preferred = codecs.enumerated().sorted {
                (priority($0.element.name), $0.offset) < (priority($1.element.name), $1.offset)
            }.map(\.element)
            try video.setCodecPreferences(preferred, error: ())
        }
        // Automatic follows the shared VP9/H.265/H.264 preference; the server selects the codec.
        // This framework exposes no receiver playoutDelayHint/jitterBufferTarget API.
        for spec in channels {
            let options = LKRTCDataChannelConfiguration()
            options.isNegotiated = spec.negotiated; options.channelId = Int32(spec.id); options.isOrdered = spec.ordered
            if let retries = spec.maxRetransmits { options.maxRetransmits = Int32(retries) }
            guard let channel = peer.dataChannel(forLabel: spec.label, configuration: options) else {
                throw StreamError.negotiationFailed
            }
            self.channels[spec.id] = channel; channel.delegate = self
        }
    }
    func createOffer(iceRestart: Bool) async throws -> String {
        guard let peer, !closed else { throw StreamError.disconnected }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                                              optionalConstraints: nil)
        let description: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let description, error == nil { continuation.resume(returning: description) }
                else { continuation.resume(throwing: StreamError.negotiationFailed) }
            }
        }
        guard !closed else { throw StreamError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: StreamError.negotiationFailed) }
            }
        }
        guard !closed else { throw StreamError.disconnected }
        return description.sdp
    }
    func setRemoteAnswer(_ sdp: String) async throws {
        guard let peer, !closed else { throw StreamError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: StreamError.negotiationFailed) }
            }
        }
    }
    func addRemoteCandidate(_ candidate: ServerMessage.Candidate) async throws {
        guard let peer, !closed else { throw StreamError.disconnected }
        guard let index = Int32(exactly: candidate.sdpMLineIndex ?? 0) else { throw StreamError.negotiationFailed }
        let native = LKRTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: index, sdpMid: candidate.sdpMid)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.add(native) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: StreamError.negotiationFailed) }
            }
        }
    }
    func setIceServers(_ servers: [ServerMessage.ICEServer]) -> Bool {
        guard let peer, !closed else { return false }
        let configuration = peer.configuration
        configuration.iceServers = iceServers(servers)
        return peer.setConfiguration(configuration)
    }
    private func iceServers(_ servers: [ServerMessage.ICEServer]) -> [LKRTCIceServer] {
        servers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
    }
    func send(_ data: Data, channelID: Int) -> Bool {
        guard !closed, let channel = channels[channelID], channel.readyState == .open else { return false }
        return channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
    func close() {
        guard !closed else { return }; closed = true
        if let frameObserver { video?.remove(frameObserver) }
        frameObserver = nil; video = nil; onTrack(nil)
        for channel in channels.values { channel.delegate = nil; channel.close() }
        channels.removeAll()
        peer?.delegate = nil; peer?.close(); peer = nil; onEvent = nil
    }
    private func attachTracks(_ transceiver: LKRTCRtpTransceiver) {
        guard !closed else { return }
        if let audio = transceiver.receiver.track as? LKRTCAudioTrack { audio.isEnabled = !config.muted }
        guard let track = transceiver.receiver.track as? LKRTCVideoTrack, video !== track else { return }
        if let frameObserver { video?.remove(frameObserver) }
        video = track
        let observer = FrameObserver { [weak self] size in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.onSize(size)
            }
        }
        frameObserver = observer; track.add(observer); onTrack(track)
    }
}

extension WebRTCPeer: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        let state: PeerConnectionState
        switch newState {
        case .new: state = .new
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        @unknown default: state = .failed
        }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }; self.onEvent?(.state(state))
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let event = PeerEvent.candidate(sdp: candidate.sdp, mid: candidate.sdpMid, index: Int(candidate.sdpMLineIndex))
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }; self.onEvent?(event)
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        Task { @MainActor [weak self] in self?.attachTracks(transceiver) }
    }
}
extension WebRTCPeer: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        let id = Int(dataChannel.channelId), open = dataChannel.readyState == .open
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }; self.onEvent?(.channel(id: id, open: open))
        }
    }
    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {}
}

private final class FrameObserver: NSObject, LKRTCVideoRenderer, Sendable {
    let onFrame: @Sendable (VideoSize) -> Void
    init(_ onFrame: @escaping @Sendable (VideoSize) -> Void) { self.onFrame = onFrame }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        onFrame(VideoSize(width: Int(frame.width), height: Int(frame.height), rotation: Int(frame.rotation.rawValue)))
    }
}
#endif
