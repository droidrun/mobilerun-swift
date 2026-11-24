// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

#if DEBUG
    import AVFoundation
    import Combine
    import MobilerunProtocol
    @preconcurrency import LiveKitWebRTC
    @testable import MobilerunStream

    /// Debug-only deterministic driver for connection and native-view validation.
    @MainActor final class ConnectionProbe: ObservableObject {
        let session: DeviceStreamSession
        let handle = DeviceStreamHandle()
        @Published var landscape = false
        @Published var lastNativeInput = "none"
        private let fingers = [NSObject(), NSObject()]
        private var timer: Timer?
        private var observingInput = false
        private var statsSubscription: AnyCancellable?
        private var hostPlayer: AVAudioPlayer?
        private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        private struct Credentials: Decodable {
            let streamUrl: URL
            let streamToken: String
            let h264Only: Bool?
        }

        init(publishCapabilities: DevicePublishCapabilities? = nil) {
            let configURL = documents.appendingPathComponent("credentials.json")
            let initial = try? JSONDecoder().decode(Credentials.self, from: Data(contentsOf: configURL))
            session = DeviceStreamSession(
                credentials: {
                    do {
                        let value = try JSONDecoder().decode(
                            Credentials.self, from: Data(contentsOf: configURL))
                        return StreamCredentials(url: value.streamUrl, token: value.streamToken)
                    } catch { return nil }
                }, config: StreamConfig(videoCodec: initial?.h264Only == true ? .h264Only : .automatic, publishCapabilities: publishCapabilities))
            startHostAudio()
            session.onDiagnostic = { [weak self] event in
                self?.mark(event)
                if event.hasPrefix("frames decoded=") { self?.auditHostAudio() }
            }
            statsSubscription = session.statsPublisher.sink { [weak self] stats in
                if let stats { self?.mark("stats \(stats)") }
                else { self?.mark("stats nil") }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pollCommand() }
            }
        }

        func mark(_ event: String) {
            let line = "\(Int(ProcessInfo.processInfo.systemUptime * 1000)) \(event)\n"
            let url = documents.appendingPathComponent("events.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }

        private func pollCommand() {
            // The composite owns its handle; find its existing native surface for the Debug driver.
            if handle.view == nil {
                func find(_ root: UIView) -> DeviceStreamUIView? {
                    if let surface = root as? DeviceStreamUIView { return surface }
                    return root.subviews.lazy.compactMap { find($0) }.first
                }
                handle.view = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).lazy.compactMap { find($0) }.first
            }
            if let view = handle.view, let size = session.videoSize {
                let targetURL = documents.appendingPathComponent("native-target.json")
                let target = (try? Data(contentsOf: targetURL)).flatMap {
                    try? JSONDecoder().decode([Double].self, from: $0)
                } ?? []
                let coordinates = target.map { String($0) }.joined(separator: "x")
                view.accessibilityValue = "\(size.width)x\(size.height)x\(coordinates)"
            }
            if !observingInput, let view = handle.view {
                observingInput = true
                view.isAccessibilityElement = true
                view.accessibilityIdentifier = "device-stream-surface"
                view.onInput = { [weak self, weak view] data, sent in
                    guard sent, let type = data.first else { return }
                    let action = type == 0 || type == 2 ? Int(data[1]) : -1
                    let pointer = type == 2 ? Int(data[9]) : -1
                    let source = view?.inputEventSource ?? "driver"
                    if source != "driver" { self?.lastNativeInput = source }
                    self?.mark("input type=\(type) action=\(action) pointer=\(pointer) sent=\(sent) native=\(source)")
                }
            }
            struct Command: Decodable {
                let action: String
                let x: Double?
                let y: Double?
                let endX: Double?
                let endY: Double?
                let value: String?
                let usage: Int?
                let enabled: Bool?
            }
            let url = documents.appendingPathComponent("command.json")
            guard let data = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            guard let command = try? JSONDecoder().decode(Command.self, from: data) else { return }
            switch command.action {
            case "benchmark":
                guard let view = handle.view else { mark("benchmark failed no view"); return }
                let benchmark = StreamBenchmark()
                Task { @MainActor [weak self, session = self.session, documents = self.documents] in
                    do {
                        let result = try await benchmark.run(session: session, view: view,
                            x: command.x ?? 0.5, y: command.y ?? 0.9)
                        let data = try JSONEncoder().encode(result)
                        try data.write(to: documents.appendingPathComponent("benchmark.json"), options: .atomic)
                        self?.mark("benchmark complete")
                    } catch { self?.mark("benchmark failed") }
                }
            case "hidden":
                session.setVisible(!(command.enabled ?? true))
                mark("hidden \(command.enabled ?? true)")
            case "wake":
                session.setVisible(true)
                session.handleWake()
                mark("wake")
            case "retry":
                session.retry()
                mark("retry")
            case "close":
                mark("forcing socket close")
                session.forceSignallingClose()
            case "refresh":
                mark("requesting refresh")
                session.requestConfigurationRefresh()
            case "tap":
                tap(x: command.x ?? 0, y: command.y ?? 0)
            case "swipe":
                gesture(x: command.x ?? 0.5, y: command.y ?? 0.8,
                        endX: command.endX ?? 0.5, endY: command.endY ?? 0.2, pinch: false)
            case "pinch":
                gesture(x: 0.3, y: 0.5, endX: 0.1, endY: 0.5, pinch: true)
            case "text":
                handle.view?.textClient.insertText(command.value ?? "")
            case "compose":
                let input = handle.view?.textClient
                input?.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
                input?.setMarkedText(command.value ?? "你", selectedRange: NSRange(location: 1, length: 0))
                input?.unmarkText()
            case "delete":
                handle.view?.textClient.deleteBackward()
            case "hardware":
                pressKey(usage: command.usage ?? 4, text: command.value ?? "a")
            case "paste":
                UIPasteboard.general.string = command.value ?? ""
                pressKey(usage: 25, text: "v", flags: .command)
            case "keyboard":
                handle.showKeyboard()
            case "hideKeyboard":
                handle.hideKeyboard()
            case "control":
                handle.view?.hasControl = command.enabled ?? false
                mark("control enabled=\(handle.view?.hasControl == true)")
            case "system":
                switch command.value {
                case "BACK": handle.sendSystemKey(.back)
                case "RECENT": handle.sendSystemKey(.recent)
                default: handle.sendSystemKey(.home)
                }
            case "rotateView":
                landscape.toggle()
                mark("view rotated")
            case "mute":
                session.setMuted(true)
                auditHostAudio()
                mark("muted")
            case "stop":
                timer?.invalidate()
                timer = nil
                session.close()
                mark("teardown status=\(session.status) videoReleased=\(session.videoTrack == nil && session.videoSize == nil) statsReleased=\(session.stats == nil) transportsReleased=\(session.transportsReleasedForTesting)")
                auditHostAudio()
                hostPlayer?.stop()
                mark("session closed")
            default: break
            }
        }

        private func pressKey(usage: Int, text: String, flags: UIKeyModifierFlags = []) {
            handle.view?.routeKey(usage: usage, text: text, down: true, flags: flags)
            handle.view?.routeKey(usage: usage, text: text, down: false, flags: flags)
        }

        private func localPoint(_ x: Double, _ y: Double) -> CGPoint? {
            guard let rect = handle.view?.renderedVideoRect else { return nil }
            return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        private func tap(x: Double, y: Double) {
            guard let view = handle.view, let point = localPoint(x, y) else { return }
            let id = ObjectIdentifier(fingers[0])
            view.beginPointer(id, at: point)
            Task { @MainActor [weak view] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                view?.endPointer(id)
            }
        }

        private func gesture(x: Double, y: Double, endX: Double, endY: Double, pinch: Bool) {
            guard let view = handle.view, let start = localPoint(x, y) else { return }
            let id = ObjectIdentifier(fingers[0])
            let second = ObjectIdentifier(fingers[1])
            view.beginPointer(id, at: start)
            if pinch, let point = localPoint(1 - x, y) { view.beginPointer(second, at: point) }
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                for step in 1...30 {
                    let progress = Double(step) / 30
                    let px = x + (endX - x) * progress
                    let py = y + (endY - y) * progress
                    if let point = localPoint(px, py) { view.movePointer(id, to: point) }
                    if pinch, let point = localPoint(1 - px, py) { view.movePointer(second, to: point) }
                    try? await Task.sleep(nanoseconds: 16_666_667)
                }
                view.endPointer(id)
                if pinch { view.endPointer(second) }
            }
        }

        private func startHostAudio() {
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback)
                try audio.setActive(true)
                let player = try AVAudioPlayer(data: Self.tone())
                player.numberOfLoops = -1
                hostPlayer = player
                guard player.play() else {
                    mark("host audio unavailable")
                    return
                }
                mark("host audio started")
            } catch { mark("host audio unavailable") }
        }

        private func auditHostAudio() {
            guard let hostPlayer else { return }
            let rtc = LKRTCAudioSession.sharedInstance()
            let category = AVAudioSession.sharedInstance().category.rawValue
            mark(
                "host audio playing=\(hostPlayer.isPlaying) clock=\(hostPlayer.deviceCurrentTime) "
                    + "rtcActive=\(rtc.isActive) activations=\(rtc.activationCount) category=\(category)")
        }

        /// A quiet generated tone proves that the embedding app's audio keeps playing.
        private static func tone() -> Data {
            let rate = 22050
            let phaseStep = 2.0 * Double.pi * 220.0 / Double(rate)
            let samples: [Int16] = (0..<(rate * 2)).map { index in
                let amplitude = sin(phaseStep * Double(index)) * 1000.0
                return Int16(amplitude)
            }
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            append(UInt32(36 + samples.count * 2))
            data.append(Data("WAVEfmt ".utf8))
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(rate))
            append(UInt32(rate * 2))
            append(UInt16(2))
            append(UInt16(16))
            data.append(Data("data".utf8))
            append(UInt32(samples.count * 2))
            samples.forEach { append($0) }
            return data
        }
    }

    private struct ConnectionView: View {
        @ObservedObject var session: DeviceStreamSession
        @ObservedObject var probe: ConnectionProbe
        var body: some View {
            VStack {
                Text("Mobilerun connection example").font(.headline)
                Text(String(describing: session.status)).font(.caption)
                if let size = session.videoSize {
                    Text("\(size.width) × \(size.height) · \(size.rotation)°").font(.caption)
                }
                DeviceStreamView(session: session, hasControl: true, handle: probe.handle)
                    .frame(height: probe.landscape ? 200 : nil)
                    .background(Color.black)
                    .overlay(alignment: .topLeading) {
                        Text(probe.lastNativeInput).font(.caption2)
                            .accessibilityIdentifier("last-native-input")
                    }
            }.padding(8)
                .onReceive(session.$status) { probe.mark("status \($0)") }
                .onReceive(session.$videoSize) {
                    if let size = $0 {
                        probe.mark("frame \(size.width)x\(size.height) rotation=\(size.rotation)")
                    }
                }
                .onAppear { session.start() }
        }
    }

    private struct NativeConnectionExample: View {
        @StateObject private var probe = ConnectionProbe()
        var body: some View { ConnectionView(session: probe.session, probe: probe) }
    }

    @main struct ConnectionApp: App {
        // The validation runners inject this distinct file before launching.
        private static var hasProbeCredentials: Bool {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("credentials.json")
            return FileManager.default.fileExists(atPath: file.path)
        }
        var body: some Scene {
            WindowGroup {
                if ProcessInfo.processInfo.arguments.contains("--default-ui") { DefaultUIExample() }
                else if Self.hasProbeCredentials {
                    NativeConnectionExample()
                }
                else { SampleAppView() }
            }
        }
    }
#else
    @main struct ConnectionApp: App {
        var body: some Scene {
            WindowGroup { Text("Build this validation example in Debug.") }
        }
    }
#endif
