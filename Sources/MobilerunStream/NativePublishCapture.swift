// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import AVFoundation
import Combine
import MobilerunStreamCore
@preconcurrency import LiveKitWebRTC

/// A capture lease exists before permission requests, so stop also fences late OS callbacks.
@MainActor final class NativePublishCapture: PublishCapture {
    var onEnded: (@MainActor () -> Void)?
    private let usageDescription: @MainActor (String) -> String?
    private var healthCheck: (any ScheduledTask)?
    private let scheduler = MainActorScheduler()
    private let options: PublishOptions
    private let audioSender: LKRTCRtpTransceiver?
    private let videoSender: LKRTCRtpTransceiver?
    private var audio: LKRTCAudioTrack?
    private var video: LKRTCVideoTrack?
    private var camera: LKRTCCameraVideoCapturer?
    private var observers: Set<AnyCancellable> = []
    private var stopped = false
    private var stopTask: Task<Void, Never>?
    private let audioID = UUID()
    init(options: PublishOptions, audio: LKRTCRtpTransceiver?, video: LKRTCRtpTransceiver?,
         usageDescription: @escaping @MainActor (String) -> String? = { Bundle.main.object(forInfoDictionaryKey: $0) as? String }) {
        self.usageDescription = usageDescription
        self.options = options; self.audioSender = audio; self.videoSender = video
    }

    func start() async throws {
        // Check all metadata before any protected API, including the first microphone prompt.
        let keys = options.video ? ["NSMicrophoneUsageDescription", "NSCameraUsageDescription"] : ["NSMicrophoneUsageDescription"]
        guard keys.allSatisfy({ usageDescription($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw PublishFailure(reason: .publishFailed, detail: "capture_configuration")
        }
        try await permission(.audio)
        if options.video { try await permission(.video) }
        try checkStopped()
        let factory = WebRTCPeer.factory
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"
        ]))
        audio = factory.audioTrack(with: source, trackId: UUID().uuidString)
        // Independent lease: muting received device audio must never close the microphone gate.
        StreamAudio.setEnabled(true, id: audioID)
        observeAudioInterruption()
        if options.video {
            let source = factory.videoSource()
            let capturer = LKRTCCameraVideoCapturer(delegate: source)
            camera = capturer
            video = factory.videoTrack(with: source, trackId: UUID().uuidString)
            guard let device = LKRTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                    ?? LKRTCCameraVideoCapturer.captureDevices().first,
                  let format = Self.format(device) else {
                throw PublishFailure(reason: .publishFailed, detail: "capture_unavailable")
            }
            let fps = Int(min(30, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24))
            observeCamera(capturer.captureSession)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                capturer.startCapture(with: device, format: format, fps: min(24, fps)) { error in
                    if error != nil { continuation.resume(throwing: PublishFailure(reason: .publishFailed, detail: "capture_unavailable")) }
                    else { continuation.resume() }
                }
            }
            // stopCapture is serialized by the native capturer; repeat after a late start completion.
            if stopped { await capturer.stopCapture() }
            try checkStopped()
        }
        checkHealth()
    }
    private func permission(_ type: AVMediaType) async throws {
        try checkStopped()
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: break
        case .notDetermined:
            let allowed = await AVCaptureDevice.requestAccess(for: type)
            try checkStopped()
            guard allowed else { throw PublishFailure(reason: .permissionDenied, detail: "capture_permission") }
        default: throw PublishFailure(reason: .permissionDenied, detail: "capture_permission")
        }
    }
    private func checkStopped() throws {
        if stopped { throw PublishFailure(reason: .publishCancelled) }
    }
    func attach(_ kind: PublishKind) throws {
        try checkStopped()
        let transceiver = kind == .audio ? audioSender : videoSender
        var direction = LKRTCRtpTransceiverDirection.inactive
        guard let transceiver, !transceiver.isStopped, transceiver.currentDirection(&direction),
              direction == .sendOnly || direction == .sendRecv else {
            throw PublishFailure(reason: .publishUnsupported, detail: "negotiated_sender")
        }
        let track: LKRTCMediaStreamTrack? = kind == .audio ? audio : video
        guard let track, track.readyState == .live else {
            throw PublishFailure(reason: .publishFailed, detail: "capture_unavailable")
        }
        transceiver.sender.track = track
        guard transceiver.sender.track?.trackId == track.trackId else {
            throw PublishFailure(reason: .publishFailed, detail: "attach_failed")
        }
        if kind == .video {
            let parameters = transceiver.sender.parameters
            for encoding in parameters.encodings { encoding.maxBitrateBps = 1_000_000 }
            transceiver.sender.parameters = parameters // A best-effort cap; native setter has no failure result.
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        onEnded = nil
        healthCheck?.cancel(); healthCheck = nil
        observers.removeAll()
        audio?.isEnabled = false
        video?.isEnabled = false
        // Compare identity so a late cleanup cannot detach a subsequent operation's track.
        if let audio, audioSender?.sender.track?.trackId == audio.trackId { audioSender?.sender.track = nil }
        if let video, videoSender?.sender.track?.trackId == video.trackId { videoSender?.sender.track = nil }
        if let camera { stopTask = Task { await camera.stopCapture() } }
        camera = nil; audio = nil; video = nil
        StreamAudio.setEnabled(false, id: audioID)
    }
    func waitForStop() async { await stopTask?.value }
    private func checkHealth() {
        guard !stopped else { return }
        let lost = audio?.readyState != .live || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || (options.video && (video?.readyState != .live || camera?.captureSession.isRunning != true
                || AVCaptureDevice.authorizationStatus(for: .video) != .authorized))
        if lost { onEnded?(); return }
        // The pinned native track API has no ended observer. Poll its state and current grants without prompting.
        healthCheck = scheduler.schedule(delayMs: 500) { [weak self] in self?.checkHealth() }
    }
    private func observeAudioInterruption() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor [weak self] in self?.onEnded?() } }
            }.store(in: &observers)
    }
    private func observeCamera(_ session: AVCaptureSession) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            NotificationCenter.default.publisher(for: name, object: session)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.onEnded?() } }
                .store(in: &observers)
        }
    }
    private static func format(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        return formats.min { a, b in
            func distance(_ format: AVCaptureDevice.Format) -> Int {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return abs(Int(size.width) - 1280) + abs(Int(size.height) - 720)
            }
            return distance(a) < distance(b)
        }
    }
}
#endif
