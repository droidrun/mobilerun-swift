// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import MobilerunStreamCore

/// Container context shared by placeholder/unavailable slots.
@MainActor public struct StreamOverlayState {
    public var status: StreamStatus
    public var size: CGSize
    public var retry: () -> Void
    public init(status: StreamStatus = .connecting, size: CGSize = .zero, retry: @escaping () -> Void = {}) {
        self.status = status; self.size = size; self.retry = retry
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}
@MainActor public struct StreamNavigationState {
    public var canControl: Bool
    public var onAction: (SystemKey) -> Void
    public init(canControl: Bool = true, onAction: @escaping (SystemKey) -> Void = { _ in }) {
        self.canControl = canControl; self.onAction = onAction
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}
/// Slots always contain their defaults. Builders inherit the stream's labels/theme and container size.
@MainActor public struct StreamSlots {
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
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

/// White-label stream chrome. The host owns start/close; this view owns visible-lifetime wake observation.
@MainActor public struct DeviceStream: View {
    @ObservedObject private var session: DeviceStreamSession
    @StateObject private var lifecycle: StreamLifecycleAdapter
    @State private var handle = DeviceStreamHandle()
    @Environment(\.streamTheme) private var theme
    private let hasControl: Bool
    private let showsNavigation: Bool
    private let slots: StreamSlots
    public init(session: DeviceStreamSession, hasControl: Bool = true,
                showsNavigation: Bool = true, slots: StreamSlots = StreamSlots()) {
        self.session = session; self.hasControl = hasControl
        self.showsNavigation = showsNavigation; self.slots = slots
        _lifecycle = StateObject(wrappedValue: StreamLifecycleAdapter(session: session))
    }
    public var body: some View {
        let presentation = StreamPresentation(status: session.status, hasControl: hasControl)
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let context = StreamOverlayState(status: session.status, size: geometry.size, retry: session.retry)
                ZStack {
                    theme.background
                    DeviceStreamView(session: session, hasControl: presentation.canControl, handle: handle)
                    if presentation.showsPlaceholder { slots.placeholder(context).allowsHitTesting(false) }
                    if presentation.showsUnavailable { slots.unavailable(context) }
                }.clipped()
            }
            if showsNavigation {
                slots.navigation(StreamNavigationState(canControl: presentation.canControl,
                                                       onAction: handle.sendSystemKey))
            }
        }
        .font(theme.typography).foregroundColor(theme.foreground)
        .onAppear { lifecycle.start() }.onDisappear { lifecycle.stop() }
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
    @Environment(\.streamLabels) private var labels
    public var state: StreamOverlayState
    public init(state: StreamOverlayState = StreamOverlayState()) { self.state = state }
    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "iphone").font(.system(size: 48)).foregroundColor(theme.mutedForeground.opacity(0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StreamStatusPill(label: label).padding(16)
        }
    }
    private var label: String {
        if case .reconnecting(let attempt) = state.status {
            return attempt > 1 ? labels.reconnectingAttempt
                .replacingOccurrences(of: "{attempt}", with: String(attempt))
                .replacingOccurrences(of: "{max}", with: String(ReconnectPolicy.maxAttempts)) : labels.reconnecting
        }
        return labels.connecting
    }
}
@MainActor public struct StreamUnavailableView: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    public var state: StreamOverlayState
    public init(state: StreamOverlayState = StreamOverlayState()) { self.state = state }
    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 40)).opacity(0.5)
            Text(labels.unavailable)
            Button(action: state.retry) { Label(labels.retry, systemImage: "arrow.clockwise") }
                .modifier(StreamChromeButton(primary: true))
        }.padding(24)
            .modifier(StreamSurfaceModifier(shape: RoundedRectangle(cornerRadius: theme.radius), fill: theme.card))
            .font(theme.typography).foregroundColor(theme.mutedForeground)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
    }
}
@MainActor public struct StreamNavigationBar: View {
    @Environment(\.streamTheme) private var theme
    @Environment(\.streamLabels) private var labels
    public var state: StreamNavigationState
    public init(state: StreamNavigationState = StreamNavigationState()) { self.state = state }
    public var body: some View {
        StreamGlassGroup {
            HStack(spacing: 8) {
                key(.back, symbol: "chevron.left", label: labels.back)
                key(.home, symbol: "house", label: labels.home)
                key(.recent, symbol: "square.grid.2x2", label: labels.recent)
            }.frame(height: 40)
        }.background(theme.background)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
    private func key(_ key: SystemKey, symbol: String, label: String) -> some View {
        Button { if state.canControl { state.onAction(key) } } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.modifier(StreamChromeButton(navigation: true)).accessibilityLabel(label).disabled(!state.canControl)
    }
}
struct StreamNavigationButtonStyle: ButtonStyle {
    @Environment(\.streamTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundColor(theme.foreground)
            .background(configuration.isPressed ? theme.muted : theme.background).opacity(enabled ? 1 : 0.5)
    }
}
struct StreamButtonStyle: ButtonStyle {
    @Environment(\.streamTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    var outline = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 10)
            .font(theme.typography)
            .foregroundColor(configuration.isPressed ? theme.accentForeground : (outline ? theme.foreground : theme.primaryForeground))
            .background(configuration.isPressed ? theme.accent : (outline ? theme.background : theme.primary))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(outline ? theme.border : .clear, lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
    }
}
#endif
