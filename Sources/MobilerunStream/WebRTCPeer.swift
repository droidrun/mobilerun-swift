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
        static let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory())
        var onEvent: (@MainActor (PeerEvent) -> Void)?
        private let config: StreamConfig
        private let onTrack: @MainActor (LKRTCVideoTrack?) -> Void
        private let onSize: @MainActor (VideoSize) -> Void
        private var peer: LKRTCPeerConnection?
        private var channels: [Int: LKRTCDataChannel] = [:]
        private var publishAudio: LKRTCRtpTransceiver?
        private var publishVideo: LKRTCRtpTransceiver?
        private(set) var supportsPublishReservations = false
        private var offeredCamera = false
        static var cameraEncoderSupported: Bool { !publishVideoCodecs.isEmpty }
        var supportsPublishCamera: Bool { offeredCamera }
        private static var publishVideoCodecs: [LKRTCRtpCodecCapability] {
            factory.rtpSenderCapabilities(forKind: "video").codecs.filter {
                $0.name.lowercased() == "h264" && $0.parameters["packetization-mode"] == "1"
                    && Self.supportsPublishProfile($0.parameters["profile-level-id"])
            }.sorted { ($0.parameters["profile-level-id"]?.hasPrefix("42") == true ? 0 : 1)
                < ($1.parameters["profile-level-id"]?.hasPrefix("42") == true ? 0 : 1) }
        }
        // RFC 6184 §8.2.2: profile and packetization mode match symmetrically, level does not.
        // The native factory advertises its maximum level (e.g. 42e034), which can encode 42e01f.
        private static func supportsPublishProfile(_ value: String?) -> Bool {
            guard let profile = value?.lowercased(), profile.count == 6,
                  ["42e0", "42c0", "4d00", "640c"].contains(String(profile.prefix(4))),
                  let maximumLevel = Int(profile.suffix(2), radix: 16) else { return false }
            return maximumLevel >= 31
        }
        private var audio: LKRTCAudioTrack?
        private var muted: Bool
        private let audioID = UUID()
        #if DEBUG
            var onDiagnostic: (@MainActor (String) -> Void)?
        #endif
        private var video: LKRTCVideoTrack?
        private var frameObserver: FrameObserver?
        private var closed = false
        private let firstFrameTiming: FirstFrameTiming

        init(
            config: StreamConfig, startedAt: TimeInterval, onTrack: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
            onSize: @escaping @MainActor (VideoSize) -> Void
        ) {
            self.firstFrameTiming = FirstFrameTiming(startedAt: startedAt)
            self.muted = config.muted
            self.config = config
            self.onTrack = onTrack
            self.onSize = onSize
        }
        func configure(_ configuration: ServerMessage.RTCConfiguration, channels: [DataChannelSpec]) throws {
            StreamAudio.setEnabled(!muted, id: audioID)
            let native = LKRTCConfiguration()
            native.sdpSemantics = .unifiedPlan
            if let object = configuration.configuration, object["iceServers"] != nil,
                configuration.iceServers == nil
            {
                throw PeerError.negotiationFailed
            }
            native.iceServers = iceServers(configuration.iceServers ?? [])
            if configuration.configuration?["iceTransportPolicy"] == .string("relay") {
                native.iceTransportPolicy = .relay
            }
            guard
                let peer = Self.factory.peerConnection(
                    with: native,
                    constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                    delegate: self)
            else {
                throw PeerError.negotiationFailed
            }
            self.peer = peer
            let recv = LKRTCRtpTransceiverInit()
            recv.direction = .recvOnly
            guard peer.addTransceiver(of: .audio, init: recv) != nil,
                let video = peer.addTransceiver(of: .video, init: recv)
            else { throw PeerError.negotiationFailed }
            let codecs = Self.factory.rtpReceiverCapabilities(forKind: "video").codecs
            if let preferred = CodecPreferences.ordered(
                codecs, h264Only: config.videoCodec == .h264Only, name: { $0.name }
            ) {
                try video.setCodecPreferences(preferred, error: ())
            }
            if config.publishCapabilities?.supportsMicrophone == true {
                let send = LKRTCRtpTransceiverInit()
                send.direction = .sendOnly
                if config.publishCapabilities?.cameraInjection == true, Self.cameraEncoderSupported {
                    publishVideo = peer.addTransceiver(of: .video, init: send)
                    if let publishVideo {
                        do { try publishVideo.setCodecPreferences(Self.publishVideoCodecs, error: ()) }
                        catch { publishVideo.stopInternal(); self.publishVideo = nil }
                    }
                }
                publishAudio = peer.addTransceiver(of: .audio, init: send)
                let opus = Self.factory.rtpSenderCapabilities(forKind: "audio").codecs.filter {
                    $0.name.lowercased() == "opus" && $0.clockRate?.intValue == 48_000 && $0.numChannels?.intValue == 2
                }
                if let publishAudio {
                    do {
                        guard !opus.isEmpty else { throw PublishFailure(reason: .publishUnsupported) }
                        try publishAudio.setCodecPreferences(opus, error: ())
                    } catch { publishAudio.stopInternal(); self.publishAudio = nil }
                }
            }
            // Automatic follows the shared VP9/H.265/H.264 preference; the server selects the codec.
            // This framework exposes no receiver playoutDelayHint/jitterBufferTarget API.
            for spec in channels {
                let options = LKRTCDataChannelConfiguration()
                options.isNegotiated = spec.negotiated
                options.channelId = Int32(spec.id)
                options.isOrdered = spec.ordered
                if let retries = spec.maxRetransmits { options.maxRetransmits = Int32(retries) }
                guard let channel = peer.dataChannel(forLabel: spec.label, configuration: options) else {
                    throw PeerError.negotiationFailed
                }
                self.channels[spec.id] = channel
                channel.delegate = self
            }
        }
        func createOffer(iceRestart: Bool) async throws -> String {
            guard let peer, !closed else { throw StreamError.disconnected }
            let constraints = LKRTCMediaConstraints(
                mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                optionalConstraints: nil)
            let description: LKRTCSessionDescription = try await withCheckedThrowingContinuation {
                continuation in
                peer.offer(for: constraints) { description, error in
                    if let description, error == nil {
                        continuation.resume(returning: description)
                    } else {
                        continuation.resume(throwing: PeerError.negotiationFailed)
                    }
                }
            }
            guard !closed else { throw StreamError.disconnected }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.setLocalDescription(description) { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PeerError.negotiationFailed)
                    }
                }
            }
            guard !closed else { throw StreamError.disconnected }
            #if DEBUG
                onDiagnostic?("offer codecs restart=\(iceRestart) names=\(Self.videoCodecs(description.sdp))")
                if let line = description.sdp.components(separatedBy: "\r\n")
                    .first(where: { $0.hasPrefix("a=ice-ufrag:") })
                {
                    onDiagnostic?("local ice-ufrag restart=\(iceRestart) value=\(line.dropFirst(12))")
                }
            #endif
            if !iceRestart {
                // Inspect generated SDP only. Never manufacture SSRCs or acquire dummy input tracks.
                supportsPublishReservations = publishAudio != nil && PublishSDP.hasReservation(description.sdp, kind: .audio)
                offeredCamera = publishVideo != nil && PublishSDP.hasReservation(description.sdp, kind: .video)
            }
            return description.sdp
        }
        func setRemoteAnswer(_ sdp: String) async throws {
            guard let peer, !closed else { throw StreamError.disconnected }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PeerError.negotiationFailed)
                    }
                }
            }
        }
        #if DEBUG
            private static func videoCodecs(_ sdp: String) -> String {
                guard let video = sdp.components(separatedBy: "m=video").dropFirst().first else { return "" }
                return video.components(separatedBy: "\r\n")
                    .filter { $0.hasPrefix("a=rtpmap:") }
                    .compactMap { $0.split(separator: " ").last?.split(separator: "/").first }
                    .map { $0.lowercased() }
                    .joined(separator: ",")
            }
        #endif

        func addRemoteCandidate(_ candidate: ServerMessage.Candidate) async throws {
            guard let peer, !closed else { throw StreamError.disconnected }
            guard let index = Int32(exactly: candidate.sdpMLineIndex ?? 0) else {
                throw PeerError.negotiationFailed
            }
            let native = LKRTCIceCandidate(
                sdp: candidate.candidate, sdpMLineIndex: index, sdpMid: candidate.sdpMid)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.add(native) { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PeerError.negotiationFailed)
                    }
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
            servers.map {
                LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
            }
        }
        func send(_ data: Data, channelID: Int) -> Bool {
            guard !closed, let channel = channels[channelID], channel.readyState == .open else {
                return false
            }
            return channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
        }
        func statistics(_ completion: @escaping StreamStatsSampler.Completion) {
            guard let peer, !closed else { completion([], nil); return }
            peer.statistics { [weak self] report in
                let records = report.statistics.values.compactMap { record in
                    projectStatistics(id: record.id, type: record.type,
                                      timestampUs: record.timestamp_us, values: record.values)
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.closed else { return }
                    completion(records, self.firstFrameTiming.value)
                }
            }
        }

        func makePublishCapture(_ options: PublishOptions) throws -> any PublishCapture {
            guard !closed else { throw PublishFailure(reason: .disconnected) }
            return NativePublishCapture(options: options, audio: publishAudio, video: publishVideo)
        }

        func setMuted(_ muted: Bool) {
            guard !closed else { return }
            self.muted = muted
            audio?.isEnabled = !muted
            StreamAudio.setEnabled(!muted, id: audioID)
        }
        deinit {
            if let frameObserver { video?.remove(frameObserver) }
            for channel in channels.values {
                channel.delegate = nil
                channel.close()
            }
            peer?.delegate = nil
            peer?.close()
            let id = audioID
            Task { @MainActor in StreamAudio.setEnabled(false, id: id) }
        }
        func close() {
            guard !closed else { return }
            closed = true
            if let frameObserver { video?.remove(frameObserver) }
            frameObserver = nil
            video = nil
            audio = nil
            onTrack(nil)
            StreamAudio.setEnabled(false, id: audioID)
            for channel in channels.values {
                channel.delegate = nil
                channel.close()
            }
            channels.removeAll()
            peer?.delegate = nil
            peer?.close()
            peer = nil
            onEvent = nil
        }
        private func attachTracks(_ transceiver: LKRTCRtpTransceiver) {
            guard !closed else { return }
            if let audio = transceiver.receiver.track as? LKRTCAudioTrack {
                self.audio = audio
                audio.isEnabled = !muted
            }
            guard let track = transceiver.receiver.track as? LKRTCVideoTrack, video !== track else { return }
            if let frameObserver { video?.remove(frameObserver) }
            video = track
            let observer = FrameObserver(timing: firstFrameTiming, onSize: { [weak self] size in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed else { return }
                    self.onSize(size)
                }
            })
            #if DEBUG
                observer.onProgress = { [weak self] count in
                    Task { @MainActor [weak self] in
                        guard let self, !self.closed else { return }
                        self.onDiagnostic?("frames decoded=\(count)")
                    }
                }
            #endif
            frameObserver = observer
            track.add(observer)
            onTrack(track)
        }
    }

    extension WebRTCPeer: PublishMediaTransport {}

    extension WebRTCPeer: LKRTCPeerConnectionDelegate {
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream
        ) {}
        nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel
        ) {}
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState
        ) {
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
                guard let self, !self.closed else { return }
                self.onEvent?(.state(state))
            }
        }
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate
        ) {
            let event = PeerEvent.candidate(
                sdp: candidate.sdp, mid: candidate.sdpMid, index: Int(candidate.sdpMLineIndex))
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.onEvent?(event)
            }
        }
        nonisolated func peerConnection(
            _ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver
        ) {
            Task { @MainActor [weak self] in self?.attachTracks(transceiver) }
        }
    }
    extension WebRTCPeer: LKRTCDataChannelDelegate {
        nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
            let id = Int(dataChannel.channelId)
            let open = dataChannel.readyState == .open
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.onEvent?(.channel(id: id, open: open))
            }
        }
        nonisolated func dataChannel(
            _ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer
        ) {}
    }

    private final class FrameObserver: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var lastSize: VideoSize?
        private var frames = 0
        private let onSize: @Sendable (VideoSize) -> Void
        private let timing: FirstFrameTiming
        #if DEBUG
            var onProgress: (@Sendable (Int) -> Void)?
        #endif

        init(timing: FirstFrameTiming, onSize: @escaping @Sendable (VideoSize) -> Void) {
            self.timing = timing
            self.onSize = onSize
        }
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: LKRTCVideoFrame?) {
            guard let frame else { return }
            timing.stamp(at: ProcessInfo.processInfo.systemUptime)
            let size = VideoSize(
                width: Int(frame.width), height: Int(frame.height), rotation: Int(frame.rotation.rawValue)
            )
            lock.lock()
            frames += 1
            let count = frames
            let changed = lastSize != size
            lastSize = size
            lock.unlock()
            if changed { onSize(size) }
            #if DEBUG
                if count == 1 || count.isMultiple(of: 60) { onProgress?(count) }
            #endif
        }
    }

    /// The native audio gate is process-wide. Received-audio playback and publication hold
    /// independent leases; the last viewer/publisher release closes the gate.
    @MainActor enum StreamAudio {
        private static var enabledSessions: Set<UUID> = []
        static func setEnabled(_ enabled: Bool, id: UUID) {
            if enabled { enabledSessions.insert(id) } else { enabledSessions.remove(id) }
            let audio = LKRTCAudioSession.sharedInstance()
            audio.useManualAudio = true
            audio.isAudioEnabled = !enabledSessions.isEmpty
        }
    }

    private enum PeerError: Error { case negotiationFailed }
#endif
