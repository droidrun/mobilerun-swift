// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MobilerunStream

struct SampleCredentials: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    let streamUrl: URL
    let streamToken: String
    var description: String { "SampleCredentials(<redacted>)" }
    var debugDescription: String { description }

    init(url: String, token: String) throws {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["ws", "wss"].contains(parsed.scheme ?? ""), parsed.host != nil,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SampleError.invalidCredentials
        }
        streamUrl = parsed
        streamToken = token
    }
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(url: fields.decode(String.self, forKey: .streamUrl),
                      token: fields.decode(String.self, forKey: .streamToken))
    }
    private enum CodingKeys: String, CodingKey { case streamUrl, streamToken }

    static func consume(_ file: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // Remove even malformed files, before decoding or reporting a safe error.
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch {
            try FileManager.default.removeItem(at: file)
            throw SampleError.invalidCredentials
        }
        try FileManager.default.removeItem(at: file)
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw SampleError.invalidCredentials }
    }
}

enum SampleError: LocalizedError {
    case invalidCredentials
    var errorDescription: String? { "Enter a WebSocket stream URL and a nonblank stream token." }
}

enum SampleAppearance: String, CaseIterable {
    case light = "Light", dark = "Dark", brand = "Brand"
    func theme(solid: Bool) -> StreamTheme {
        var theme: StreamTheme = self == .dark ? .dark : .light
        if self == .brand { theme.primary = .indigo; theme.radius = 20 }
        theme.surfaceStyle = solid ? .solid : .glass
        return theme
    }
    var labels: StreamLabels {
        self == .brand ? StreamLabels().with {
            $0.back = "Go back"; $0.home = "Start"; $0.recent = "Apps"; $0.retry = "Try again"
        } : StreamLabels()
    }
    var approvalLabels: TaskApprovalLabels {
        self == .brand ? TaskApprovalLabels().with { $0.approve = "Allow"; $0.deny = "Decline" } : TaskApprovalLabels()
    }
}

/// Local backend stand-in: no network, polling, or real task.
@MainActor final class SampleApproval: ObservableObject {
    @Published var result = ""
    private var pending: PendingApproval?
    private var fetchCount = 0
    lazy var model = TaskApprovalModel(taskId: "sample", fetchApproval: { [weak self] _ in
        guard let self else { return nil }
        self.fetchCount += 1
        if self.pending == nil { self.result += " · refetch \(self.fetchCount)" }
        return self.pending
    }, decide: { [weak self] _, _, decision in
        self?.pending = nil
        self?.result = "Decision: \(decision.rawValue)"
    }, subscribe: { _, _ in .success({ .success(()) }) })

    func show() {
        model.stop()
        fetchCount = 0
        result = ""
        pending = PendingApproval(approvalId: UUID().uuidString, kind: "payment_card", details: [
            "label": .string("Visa 4242"), "targetPackage": .string("com.example.shop")
        ], expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30)))
        model.start()
    }
}

@MainActor final class SampleConnection: ObservableObject {
    @Published var session: DeviceStreamSession?
    @Published var url = ""
    @Published var token = ""
    @Published var error: String?
    init() {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample-credentials.json")
        do {
            if let credentials = try SampleCredentials.consume(file) {
                url = credentials.streamUrl.absoluteString
                token = credentials.streamToken
                connect()
            }
        } catch { self.error = SampleError.invalidCredentials.localizedDescription }
    }
    func connect() {
        do {
            let credentials = try SampleCredentials(url: url, token: token)
            session?.close()
            let next = DeviceStreamSession(credentials: {
                StreamCredentials(url: credentials.streamUrl, token: credentials.streamToken)
            })
            session = next
            error = nil
            next.start()
        } catch { self.error = SampleError.invalidCredentials.localizedDescription }
    }
}

@MainActor struct SampleAppView: View {
    @StateObject private var connection = SampleConnection()
    @StateObject private var approval = SampleApproval()
    @State private var appearance = SampleAppearance.light
    @State private var solid = false
    @State private var showStats = false
    @State private var showCredentials = false
    @State private var showApproval = false
    var body: some View {
        VStack(spacing: 8) {
            Text("Mobilerun sample").font(.headline)
            if connection.session == nil || showCredentials {
                TextField("Stream URL", text: $connection.url)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityIdentifier("stream-url")
                SecureField("Stream token", text: $connection.token).accessibilityIdentifier("stream-token")
                Button("Connect") { connection.connect(); showCredentials = connection.error != nil }
            }
            if let error = connection.error { Text(error).font(.caption).foregroundColor(.red) }
            Picker("Theme", selection: $appearance) {
                ForEach(SampleAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Solid chrome", isOn: $solid).accessibilityIdentifier("solid-chrome")
            HStack {
                Button("Credentials") { showCredentials.toggle() }
                Button("Reconnect") { connection.connect() }.disabled(connection.session == nil)
                Button(showStats ? "Hide stats" : "Stats") { showStats.toggle() }
            }.font(.caption)
            Button("Demo approval") { approval.show(); showApproval = true }
            if !approval.result.isEmpty {
                Text(approval.result).font(.caption).accessibilityIdentifier("sample-decision")
            }
            if let session = connection.session {
                SampleStreamView(session: session, showStats: showStats)
            } else {
                Text("Connect to a device to try video and input.")
                Spacer()
            }
        }
        .padding(12)
        .sheet(isPresented: $showApproval) {
            ScrollView {
                VStack(spacing: 16) {
                    SampleApprovalView(approval: approval, model: approval.model)
                    Button("Close demo") { showApproval = false }
                }.padding(16)
            }
        }
        .onReceive(approval.$result) { result in
            if result.hasPrefix("Decision:") { showApproval = false }
        }
        .streamTheme(appearance.theme(solid: solid))
        .streamLabels(appearance.labels)
        .taskApprovalLabels(appearance.approvalLabels)
        .preferredColorScheme(appearance == .dark ? .dark : .light)
        .onDisappear { connection.session?.close(); approval.model.stop() }
    }
}

@MainActor private struct SampleApprovalView: View {
    @ObservedObject var approval: SampleApproval
    @ObservedObject var model: TaskApprovalModel
    var body: some View {
        VStack {
            if model.state.approval != nil {
                TaskApprovalCard(state: model.state, onDecide: model.decide)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor private struct SampleStreamView: View {
    @ObservedObject var session: DeviceStreamSession
    let showStats: Bool
    @State private var keyboardMode = false
    var body: some View {
        VStack(spacing: 4) {
            if showStats { SampleStatsView(session: session) }
            Toggle("Keyboard mode", isOn: $keyboardMode).font(.caption)
            if keyboardMode {
                SampleKeyboardView(session: session)
            } else {
                DeviceStream(session: session).accessibilityIdentifier("sample-stream")
            }
        }
    }
}

/// Explicit input controls use the native view's public handle and lifecycle adapter.
@MainActor private struct SampleKeyboardView: View {
    @ObservedObject var session: DeviceStreamSession
    @State private var input = DeviceStreamHandle()
    @StateObject private var lifecycle: StreamLifecycleAdapter
    init(session: DeviceStreamSession) {
        self.session = session
        _lifecycle = StateObject(wrappedValue: StreamLifecycleAdapter(session: session))
    }
    var body: some View {
        VStack {
            DeviceStreamView(session: session, hasControl: true, handle: input)
                .accessibilityIdentifier("sample-input-stream")
            HStack {
                Button("Keyboard") { input.showKeyboard() }
                Button("Hide keyboard") { input.hideKeyboard() }
            }.font(.caption)
            StreamNavigationBar(state: StreamNavigationState(
                canControl: session.status != .unavailable, onAction: input.sendSystemKey))
        }.onAppear { lifecycle.start() }.onDisappear { lifecycle.stop() }
            .onChange(of: ObjectIdentifier(session)) { _ in lifecycle.rebind(session: session) }
    }
}

@MainActor private struct SampleStatsView: View {
    let session: DeviceStreamSession
    @State private var stats: StreamStats?
    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FPS \(number(stats?.fps)) · kbit/s \(number(stats?.bitrateKbps))")
            Text("RTT \(number(stats?.rttMs)) ms · jitter \(number(stats?.jitterBufferDelayMs)) ms")
            Text("ICE \(stats?.localCandidateType ?? "—") / \(stats?.remoteCandidateType ?? "—")")
            Text("First frame \(number(stats?.timeToFirstFrameMs)) ms")
        }.font(.caption.monospacedDigit())
            .accessibilityIdentifier("sample-stats")
            .onReceive(session.statsPublisher) { stats = $0 }
    }
}
