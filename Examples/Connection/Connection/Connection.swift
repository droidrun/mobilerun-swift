// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
@preconcurrency import LiveKitWebRTC
@_spi(Testing) import MobilerunStream

/// A validation harness, not a reusable renderer or input-mapping component.
@MainActor final class ConnectionProbe: ObservableObject {
    let session: DeviceStreamSession
    private var timer: Timer?
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        let configURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("credentials.json")
        session = DeviceStreamSession(credentials: {
            struct Credentials: Decodable { let streamUrl: URL; let streamToken: String }
            do {
                let value = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: configURL))
                return StreamCredentials(url: value.streamUrl, token: value.streamToken)
            } catch { return nil }
        })
        session.onDiagnostic = { [weak self] event in self?.mark(event) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollCommand() }
        }
    }
    func mark(_ event: String) {
        let line = "\(Int(ProcessInfo.processInfo.systemUptime * 1000)) \(event)\n"
        let url = documents.appendingPathComponent("events.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        }
    }
    private func pollCommand() {
        struct Command: Decodable { let action: String; let x: Double?; let y: Double? }
        let url = documents.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else { return }
        switch command.action {
        case "close": mark("forcing socket close"); session.forceSignallingClose()
        case "refresh": mark("requesting refresh"); session.requestConfigurationRefresh()
        case "tap": tap(x: command.x ?? 0, y: command.y ?? 0)
        case "stop": timer?.invalidate(); timer = nil; session.close(); mark("closed")
        default: break
        }
    }
    private func tap(x: Double, y: Double) {
        guard let size = session.videoSize else { mark("tap rejected"); return }
        // Raw video coordinates deliberately avoid adding S3 input/view mapping.
        let down = session.sendControl(ControlMessages.touch(action: 0, pointerID: 0,
            videoWidth: size.width, videoHeight: size.height, x: x, y: y, actionButton: 1, buttons: 1))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            let up = session.sendControl(ControlMessages.touch(action: 1, pointerID: 0,
                videoWidth: size.width, videoHeight: size.height, x: x, y: y, actionButton: 1, buttons: 1))
            mark("tap down=\(down) up=\(up) x=\(Int(x)) y=\(Int(y))")
        }
    }
}
private struct Preview: UIViewRepresentable {
    let track: LKRTCVideoTrack?
    final class Coordinator { var track: LKRTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView(frame: .zero); view.videoContentMode = .scaleAspectFit; return view
    }
    func updateUIView(_ view: LKRTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view); context.coordinator.track = track; track?.add(view)
    }
    static func dismantleUIView(_ view: LKRTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view); coordinator.track = nil
    }
}
private struct ConnectionView: View {
    @ObservedObject var session: DeviceStreamSession
    let probe: ConnectionProbe
    var body: some View {
        VStack {
            Text("Mobilerun connection example").font(.headline)
            Text(String(describing: session.status)).font(.caption)
            if let size = session.videoSize { Text("\(size.width) × \(size.height) · \(size.rotation)°").font(.caption) }
            Preview(track: session.videoTrack).background(Color.black)
        }.padding(8)
        .onReceive(session.$status) { probe.mark("status \($0)") }
        .onReceive(session.$videoSize) { if let size = $0 { probe.mark("frame \(size.width)x\(size.height) rotation=\(size.rotation)") } }
        .onAppear { session.start() }
    }
}
@main struct ConnectionApp: App {
    @StateObject private var probe = ConnectionProbe()
    var body: some Scene { WindowGroup { ConnectionView(session: probe.session, probe: probe) } }
}
