// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import MobilerunStreamCore

/// Floating chrome shares the stream's labels and surface theme; it never changes video layout.
@MainActor struct StreamPublishPill: View {
    @ObservedObject var session: DeviceStreamSession
    let presentation: PublishPresentation
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    @StateObject private var interaction = PublishPillInteraction()
    @State private var changingKinds = false
    @State private var actionTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 8) {
            if let label = labels.publishLabel(session.publishState) {
                Text(label).font(theme.typography).multilineTextAlignment(.center)
                    .padding(8).modifier(StreamSurfaceModifier(shape: Capsule(), fill: theme.card))
                    .accessibilityIdentifier("stream-publish-message")
                    .allowsHitTesting(false)
            }
            HStack(spacing: 8) {
                control(video: false)
                if presentation.cameraVisible { control(video: true) }
            }
            .padding(6)
            .background {
                Color.clear.modifier(StreamSurfaceModifier(shape: Capsule(), fill: theme.card))
                    .allowsHitTesting(false)
            }
            .background(PublishPillProximity(onInteraction: interaction.interact).allowsHitTesting(false))
            .opacity(interaction.opacity)
            .animation(.easeInOut(duration: 0.2), value: interaction.opacity)
            .disabled(presentation.starting || changingKinds || session.status != .connected || session.isClosed)
        }
        .foregroundColor(theme.cardForeground)
        .onAppear { interaction.interact() }
        .onDisappear { interaction.stop(); actionTask?.cancel(); actionTask = nil }
    }
    private func control(video: Bool) -> some View {
        let live = session.publishState.phase == .active
            && session.publishState.kinds.contains(video ? .video : .audio)
        let label = video ? (live ? labels.stopCamera : labels.camera) : (live ? labels.stopMicrophone : labels.microphone)
        return Button {
            interaction.interact()
            changingKinds = true
            actionTask = Task { @MainActor in
                let state = session.publishState
                await session.stopPublish()
                guard !Task.isCancelled else { changingKinds = false; return }
                // Kinds are immutable on the wire. A camera toggle explicitly stops then starts.
                if video || state.phase != .active {
                    _ = try? await session.startPublish(PublishOptions(audio: true, video: video && !(state.phase == .active && state.kinds.contains(.video))))
                }
                changingKinds = false
            }
        } label: {
            Image(systemName: video ? (live ? "video.fill" : "video.slash") : (live ? "mic.fill" : "mic.slash"))
                .frame(width: 44, height: 44)
                .foregroundColor(live ? theme.destructive : theme.cardForeground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(live ? .isSelected : [])
        .accessibilityIdentifier(video ? "stream-publish-camera" : "stream-publish-microphone")
    }
}
#endif
