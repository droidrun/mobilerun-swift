import SwiftUI
@preconcurrency import LiveKitWebRTC

// Throwaway protocol probe. All session operations run on the main queue.
final class StreamProbe: NSObject, ObservableObject, @unchecked Sendable {
    @Published var status = "Ready"
    @Published var details = ""
    let renderer: LKRTCMTLVideoView
    private let factory = LKRTCPeerConnectionFactory(
        encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
    private var pc: LKRTCPeerConnection?
    private var socket: URLSessionWebSocketTask?
    private var timer: Timer?
    private var control: LKRTCDataChannel?
    private var hover: LKRTCDataChannel?
    private var video: LKRTCVideoTrack?
    private var pending: [LKRTCIceCandidate] = []
    private var answered = false
    private var startTime = ProcessInfo.processInfo.systemUptime
    private var sessionID = UUID().uuidString
    private var mode = "default"
    private var generation = 0
    private var firstFrame = false
    private var width = 0
    private var height = 0
    var viewSize = CGSize.zero
    private var frameProbe: FrameProbe?
    private let logURL = URL.documentsDirectoryCompat.appendingPathComponent("events.log")

    @MainActor override init() {
        renderer = LKRTCMTLVideoView(frame: .zero)
        super.init()
        renderer.videoContentMode = .scaleAspectFit
    }
    func mark(_ event: String) {
        let line = "\(Int((ProcessInfo.processInfo.systemUptime - startTime) * 1000))ms \(event)\n"
        print(line, terminator: "")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let file = try? FileHandle(forWritingTo: logURL) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: Data(line.utf8)); try? file.close()
        }
    }
    func start(h264Only: Bool = false) {
        stop()
        generation += 1
        startTime = ProcessInfo.processInfo.systemUptime
        sessionID = UUID().uuidString
        firstFrame = false; width = 0; height = 0; answered = false; pending = []
        mode = h264Only ? "h264-only" : "default"
        mark("START mode=\(mode)")
        do {
            let bytes = try Data(contentsOf: URL.documentsDirectoryCompat.appendingPathComponent("spike.json"))
            let credentials = try JSONDecoder().decode(Credentials.self, from: bytes)
            guard var url = URLComponents(string: credentials.streamUrl) else { throw ProbeError.config }
            var query = url.queryItems ?? []
            query.removeAll { $0.name == "token" }
            query.append(URLQueryItem(name: "token", value: credentials.streamToken))
            url.queryItems = query
            guard let endpoint = url.url else { throw ProbeError.config }
            let ws = URLSession.shared.webSocketTask(with: endpoint)
            socket = ws; ws.resume(); status = "Connecting (\(mode))"
            receive(ws, generation: generation)
            send(["type": "requestRtcConfiguration", "supportsLiveRtcRefresh": true])
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.send(["type": "keepAlive"]); self?.stats()
            }
        } catch { status = "Config unavailable"; mark("ERROR config (details suppressed)") }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        video?.remove(renderer)
        if let frameProbe { video?.remove(frameProbe) }
        video = nil; frameProbe = nil
        control?.close(); hover?.close(); control = nil; hover = nil
        pc?.close(); pc = nil
    }
    private func send(_ payload: [String: Any]) {
        var message = payload; message["sessionId"] = sessionID
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.mark("WS send failed (details suppressed)") } }
        }
    }
    private func receive(_ ws: URLSessionWebSocketTask, generation captured: Int) {
        ws.receive { [weak self, weak ws] result in
            DispatchQueue.main.async {
                guard let self, let ws, self.socket === ws, self.generation == captured else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: return
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(json)
                    }
                    self.receive(ws, generation: captured)
                case .failure:
                    let code = (ws.response as? HTTPURLResponse)?.statusCode ?? 0
                    self.mark("WS closed http=\(code) close=\(ws.closeCode.rawValue)")
                    self.status = "WebSocket closed"
                }
            }
        }
    }
    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if type != "candidate" { mark("RECEIVE \(type)") }
        switch type {
        case "rtcConfiguration":
            guard let json = message["rtcConfiguration"] as? [String: Any] else { return }
            let configuration = LKRTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.iceServers = (json["iceServers"] as? [[String: Any]] ?? []).map { item in
                let urls = item["urls"] as? [String] ?? (item["urls"] as? String).map { [$0] } ?? []
                return LKRTCIceServer(urlStrings: urls, username: item["username"] as? String,
                                    credential: item["credential"] as? String)
            }
            if (json["iceTransportPolicy"] as? String) == "relay" { configuration.iceTransportPolicy = .relay }
            if let pc {
                let success = pc.setConfiguration(configuration)
                mark("setConfiguration=\(success)")
                if success { offer(restart: true) }
            } else { setup(configuration) }
        case "answer":
            guard let pc, let sdp = message["sdp"] as? String else { return }
            let codecLines = sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=rtpmap:") }
            mark("answerCodecs=\(codecLines.joined(separator: ";"))")
            let captured = generation
            pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.generation == captured else { return }
                    if error != nil { self.mark("ERROR remote description"); return }
                    self.answered = true; self.mark("answerApplied")
                    self.pending.forEach { pc.add($0) { _ in } }; self.pending = []
                }
            }
        case "candidate":
            guard let candidate = message["candidate"] as? String else { return }
            let value = LKRTCIceCandidate(sdp: candidate,
                sdpMLineIndex: (message["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0,
                sdpMid: message["sdpMid"] as? String)
            if answered { pc?.add(value) { _ in } } else { pending.append(value) }
        case "error": mark("SERVER error (details suppressed)")
        default: break
        }
    }
    private func setup(_ configuration: LKRTCConfiguration) {
        guard let connection = factory.peerConnection(with: configuration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        else { mark("ERROR peer creation"); return }
        pc = connection
        let recv = LKRTCRtpTransceiverInit(); recv.direction = .recvOnly
        _ = connection.addTransceiver(of: .audio, init: recv)
        let transceiver = connection.addTransceiver(of: .video, init: recv)
        let codecs = factory.rtpReceiverCapabilities(forKind: "video").codecs
        mark("receiverCodecs=\(codecs.map(\.name).joined(separator: ","))")
        if mode == "h264-only", let transceiver {
            do {
                try transceiver.setCodecPreferences(
                    codecs.filter { $0.name.lowercased() == "h264" }, error: ())
                mark("setCodecPreferences H264-only OK")
            } catch { mark("ERROR codec preferences") }
        }
        let reliable = LKRTCDataChannelConfiguration()
        reliable.isNegotiated = true; reliable.channelId = 1; reliable.isOrdered = true
        control = connection.dataChannel(forLabel: "control", configuration: reliable); control?.delegate = self
        let lossy = LKRTCDataChannelConfiguration()
        lossy.isNegotiated = true; lossy.channelId = 2; lossy.isOrdered = false; lossy.maxRetransmits = 0
        hover = connection.dataChannel(forLabel: "hover", configuration: lossy); hover?.delegate = self
        offer(restart: false)
    }
    private func offer(restart: Bool) {
        guard let pc else { return }
        answered = false; pending = []
        let captured = generation
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: restart ? ["IceRestart": "true"] : nil,
                                              optionalConstraints: nil)
        let oldUfrag = pc.localDescription?.sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ice-ufrag:") }
        pc.offer(for: constraints) { [weak self] description, error in
            guard let description, error == nil else { return }
            let newUfrag = description.sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ice-ufrag:") }
            let ufragChanged = oldUfrag != newUfrag
            pc.setLocalDescription(description) { error in
                DispatchQueue.main.async {
                    guard let self, self.generation == captured else { return }
                    guard error == nil else { self.mark("ERROR local description"); return }
                    let codecLines = description.sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=rtpmap:") }
                    self.mark("iceUfragChanged=\(ufragChanged) restart=\(restart)")
                    self.mark("offer restart=\(restart) codecs=\(codecLines.joined(separator: ";"))")
                    self.send(["type": "offer", "sdp": description.sdp])
                }
            }
        }
    }
    func stats() {
        pc?.statistics { [weak self] report in
            let selected = report.statistics.values.filter { $0.type == "inbound-rtp" || $0.type == "codec" }
            let lines = selected.map { value in
                let fields = ["kind", "mimeType", "codecId", "framesDecoded", "framesReceived", "framesDropped", "bytesReceived", "decoderImplementation"]
                return value.id + " " + fields.compactMap { key in value.values[key].map { "\(key)=\($0)" } }.joined(separator: " ")
            }
            DispatchQueue.main.async { self?.mark("STATS \(lines.joined(separator: "; "))") }
        }
    }
    func closeWebSocketOnly() {
        mark("FORCE_WS_CLOSE leaving peer alive"); stats()
        socket?.cancel(with: .normalClosure, reason: nil)
        status = "WebSocket closed by probe"
    }
    func restartICE() {
        mark("REQUEST_CONFIG_REFRESH")
        send(["type": "requestRtcConfiguration", "supportsLiveRtcRefresh": true])
    }
    func tap(_ point: CGPoint) {
        guard width > 0, height > 0, control?.readyState == .open else { mark("tap rejected: not ready"); return }
        let scale = min(viewSize.width / CGFloat(width), viewSize.height / CGFloat(height))
        let actual = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        let x = point.x - (viewSize.width - actual.width) / 2
        let y = point.y - (viewSize.height - actual.height) / 2
        guard x >= 0, y >= 0, x <= actual.width, y <= actual.height else { mark("tap rejected: letterbox"); return }
        let videoX = Int((x / scale).rounded()), videoY = Int((y / scale).rounded())
        func packet(_ action: UInt8) -> Data {
            var bytes = Data([2, action])
            // pointerId = 0, big-endian; every remaining multibyte value is little-endian.
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
            func le<T: FixedWidthInteger>(_ value: T) {
                var value = value.littleEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            }
            le(Int32(videoX)); le(Int32(videoY)); le(UInt16(width)); le(UInt16(height))
            le(UInt16.max); le(Int32(1)); le(Int32(1))
            return bytes
        }
        let down = control?.sendData(LKRTCDataBuffer(data: packet(0), isBinary: true)) ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            let up = self?.control?.sendData(LKRTCDataBuffer(data: packet(1), isBinary: true)) ?? false
            self?.mark("tap video=(\(videoX),\(videoY)) of \(self?.width ?? 0)x\(self?.height ?? 0) down=\(down) up=\(up)")
        }
    }
    func command(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func number(_ key: String) -> Double { Double(query.first { $0.name == key }?.value ?? "") ?? 0 }
        switch url.host {
        case "tap": tap(CGPoint(x: number("x"), y: number("y")))
        case "close": closeWebSocketOnly()
        case "connect": start(h264Only: query.contains { $0.name == "codec" && $0.value == "h264" })
        case "restart": restartICE()
        case "stats": stats()
        default: break
        }
    }
    private func attach(_ track: LKRTCVideoTrack) {
        guard video?.trackId != track.trackId else { return }
        video = track; track.add(renderer)
        let captured = generation
        let probe = FrameProbe { [weak self] width, height in
            DispatchQueue.main.async {
                guard let self, self.generation == captured, !self.firstFrame else { return }
                self.firstFrame = true; self.width = width; self.height = height
                self.status = "Live (\(self.mode))"
                self.details = "\(width)×\(height) · first frame \(Int((ProcessInfo.processInfo.systemUptime - self.startTime) * 1000)) ms"
                self.mark("FIRST_DECODED_FRAME \(width)x\(height) view=\(self.viewSize)")
            }
        }
        frameProbe = probe; track.add(probe); mark("videoTrack attached")
    }
}

extension StreamProbe: LKRTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        if let track = stream.videoTracks.first { DispatchQueue.main.async { guard self.pc === peerConnection else { return }; self.attach(track) } }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        DispatchQueue.main.async { guard self.pc === peerConnection else { return }; self.mark("ICE state=\(newState.rawValue)") }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        DispatchQueue.main.async { guard self.pc === peerConnection else { return }; self.mark("PC state=\(newState.rawValue)") }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        DispatchQueue.main.async {
            guard self.pc === peerConnection else { return }
            self.send(["type": "candidate", "candidate": candidate.sdp,
                       "sdpMid": candidate.sdpMid ?? "", "sdpMLineIndex": candidate.sdpMLineIndex])
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? LKRTCVideoTrack {
            DispatchQueue.main.async { guard self.pc === peerConnection else { return }; self.attach(track) }
        }
    }
}
extension StreamProbe: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        DispatchQueue.main.async {
            guard self.control === dataChannel || self.hover === dataChannel else { return }
            self.mark("channel \(dataChannel.label) state=\(dataChannel.readyState.rawValue)")
            if self.control === dataChannel, dataChannel.readyState == .open {
                for index in 0..<12 {
                    let captured = self.generation
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.125) {
                        guard self.generation == captured else { return }
                        self.send(["type": "requestFrame"])
                    }
                }
            }
        }
    }
    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {}
}
final class FrameProbe: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    let onFrame: @Sendable (Int, Int) -> Void
    init(_ callback: @escaping @Sendable (Int, Int) -> Void) { onFrame = callback }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        if let frame { onFrame(Int(frame.width), Int(frame.height)) }
    }
}
private struct Credentials: Decodable { let streamUrl: String; let streamToken: String }
private enum ProbeError: Error { case config }
private extension URL {
    static var documentsDirectoryCompat: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
}
struct VideoSurface: UIViewRepresentable {
    let probe: StreamProbe
    func makeUIView(context: Context) -> LKRTCMTLVideoView { probe.renderer }
    func updateUIView(_ uiView: LKRTCMTLVideoView, context: Context) {}
}
@main struct StreamSpikeApp: App {
    @StateObject private var probe = StreamProbe()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Mobilerun Swift stream spike").font(.headline)
                Text(probe.status).font(.subheadline)
                Text(probe.details).font(.caption)
                GeometryReader { geometry in
                    VideoSurface(probe: probe).background(Color.black)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { probe.tap($0.location) })
                        .onAppear { probe.viewSize = geometry.size }
                        .onChange(of: geometry.size) { probe.viewSize = $0 }
                }
                HStack {
                    Button("Connect") { probe.start() }
                    Button("Close WS") { probe.closeWebSocketOnly() }
                    Button("ICE restart") { probe.restartICE() }
                }.font(.caption)
            }.padding(8).onOpenURL { probe.command($0) }
        }
    }
}
