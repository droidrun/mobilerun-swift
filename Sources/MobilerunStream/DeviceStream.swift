// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import MobilerunStreamCore

/// Stream context shared by placeholder/unavailable slots.
@MainActor public struct StreamOverlayState {
    public var status: StreamStatus
    public var hasVideo: Bool
    public var labels: StreamLabels
    public var retry: () -> Void
    /// Latest failed attempt, for slots that explain why the stream is not live.
    public var error: StreamConnectionError?
    public init(status: StreamStatus = .connecting, labels: StreamLabels,
                hasVideo: Bool = false, error: StreamConnectionError? = nil, retry: @escaping () -> Void) {
        self.status = status; self.labels = labels; self.hasVideo = hasVideo; self.error = error; self.retry = retry
    }
}
@MainActor public struct StreamNavigationState {
    public var canControl: Bool
    public var onAction: (SystemKey) -> Void
    public init(canControl: Bool = true, onAction: @escaping (SystemKey) -> Void) {
        self.canControl = canControl; self.onAction = onAction
    }
}
/// Slots always contain their defaults. Builders inherit the stream's labels/theme.
@MainActor public struct StreamSlots: StreamCustomizable {
    public var placeholder: (StreamOverlayState) -> AnyView
    public var unavailable: (StreamOverlayState) -> AnyView
    public var navigation: (StreamNavigationState) -> AnyView
    public init(
        placeholder: @escaping (StreamOverlayState) -> AnyView = { AnyView(StreamPlaceholder(state: $0)) },
        unavailable: @escaping (StreamOverlayState) -> AnyView = { AnyView(StreamUnavailableView(state: $0)) },
        navigation: @escaping (StreamNavigationState) -> AnyView = { AnyView(StreamNavigationBar(state: $0)) }
    ) {
        self.placeholder = placeholder; self.unavailable = unavailable; self.navigation = navigation
    }
}

/// White-label stream chrome. The host owns start/close; this view owns visible-lifetime wake observation.
@MainActor public struct DeviceStream: View {
    @ObservedObject private var session: DeviceStreamSession
    @StateObject private var lifecycle: StreamLifecycleAdapter
    @State private var defaultHandle = DeviceStreamHandle()
    private let suppliedHandle: DeviceStreamHandle?
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    private let hasControl: Bool
    private let showsPublishControls: Bool
    private let showsNavigation: Bool
    private let slots: StreamSlots
    public init(session: DeviceStreamSession, hasControl: Bool = true,
                showsNavigation: Bool = true, slots: StreamSlots = StreamSlots(),
                handle: DeviceStreamHandle? = nil) {
        self.init(session: session, hasControl: hasControl, showsNavigation: showsNavigation,
                  slots: slots, handle: handle, showsPublishControls: true)
    }
    public init(session: DeviceStreamSession, hasControl: Bool = true,
                showsNavigation: Bool = true, slots: StreamSlots = StreamSlots(),
                handle: DeviceStreamHandle? = nil, showsPublishControls: Bool = true) {
        self.session = session; self.hasControl = hasControl
        self.showsPublishControls = showsPublishControls
        self.showsNavigation = showsNavigation; self.slots = slots; self.suppliedHandle = handle
        _lifecycle = StateObject(wrappedValue: StreamLifecycleAdapter(session: session))
    }
    public var body: some View {
        let handle = suppliedHandle ?? defaultHandle
        let presentation = StreamPresentation(status: session.status, hasControl: hasControl, isClosed: session.isClosed)
        VStack(spacing: 0) {
            let context = StreamOverlayState(status: session.status, labels: labels, hasVideo: session.videoSize != nil, error: session.lastError, retry: session.retry)
            ZStack {
                theme.background
                DeviceStreamView(session: session, hasControl: presentation.canControl, handle: handle)
                if presentation.showsPlaceholder { slots.placeholder(context).allowsHitTesting(false) }
                if presentation.showsUnavailable { slots.unavailable(context) }
            }
            .overlay(alignment: .bottom) {
                let publish = PublishPresentation(capabilities: session.publishCapabilities,
                    cameraSupported: session.supportsPublishCamera, shown: showsPublishControls,
                    phase: session.publishState.phase)
                if publish.visible {
                    StreamPublishPill(session: session, presentation: publish).padding(16)
                }
            }.clipped()
            if showsNavigation {
                slots.navigation(StreamNavigationState(canControl: presentation.canControl,
                                                       onAction: handle.sendSystemKey))
            }
        }
        .font(theme.typography).foregroundColor(theme.foreground)
        .onAppear { lifecycle.rebind(session: session); lifecycle.start() }
        .onChange(of: ObjectIdentifier(session)) { _ in lifecycle.rebind(session: session) }
        .onDisappear {
            lifecycle.stop()
            Task { await session.stopPublish() }
        }
    }
}

/// Small spinner and label; its parent controls placement.
@MainActor public struct StreamStatusPill: View {
    @Environment(\.streamTheme) private var theme
    public var label: String
    public init(label: String) { self.label = label }
    public var body: some View {
        HStack(spacing: 10) {
            ProgressView().progressViewStyle(.circular).tint(theme.mutedForeground).scaleEffect(0.75)
            Text(label)
        }
        .font(theme.typography).foregroundColor(theme.mutedForeground)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(StreamSurfaceModifier(shape: Capsule(), fill: theme.card))
        .accessibilityElement(children: .combine)
    }
}
@MainActor public struct StreamPlaceholder: View {
    @Environment(\.streamTheme) private var theme
    public var state: StreamOverlayState
    public init(state: StreamOverlayState) { self.state = state }
    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !state.hasVideo {
                Image(systemName: "iphone").font(.system(size: 48)).foregroundColor(theme.mutedForeground.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("stream-phone-placeholder")
            }
            StreamStatusPill(label: state.labels.statusLabel(state.status, error: state.error)).padding(16)
        }
        // An opaque backing prevents native glass from sampling retained reconnecting video.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
@MainActor public struct StreamUnavailableView: View {
    @Environment(\.streamTheme) private var theme
    public var state: StreamOverlayState
    public init(state: StreamOverlayState) { self.state = state }
    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 40)).opacity(0.5)
            Text(state.labels.unavailable)
            Button(action: state.retry) { Label(state.labels.retry, systemImage: "arrow.clockwise") }
                .modifier(StreamChromeButton(kind: .primary))
        }.padding(24)
            .modifier(StreamSurfaceModifier(shape: RoundedRectangle(cornerRadius: theme.cardRadius), fill: theme.card))
            .font(theme.typography).foregroundColor(theme.mutedForeground)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
    }
}
@MainActor public struct StreamNavigationBar: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    public var state: StreamNavigationState
    public init(state: StreamNavigationState) { self.state = state }
    public var body: some View {
        StreamGlassGroup {
            HStack(spacing: 8) {
                key(.back, symbol: "chevron.left", label: labels.back)
                key(.home, symbol: "house", label: labels.home)
                key(.recent, symbol: "square.grid.2x2", label: labels.recent)
            }.frame(height: StreamMetrics.navigationHeight)
        }.background(theme.background)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
    private func key(_ key: SystemKey, symbol: String, label: String) -> some View {
        Button { if state.canControl { state.onAction(key) } } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.modifier(StreamChromeButton(kind: .navigation)).accessibilityLabel(label).disabled(!state.canControl)
    }
}
#endif
