// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI

enum StreamMetrics {
    static let navigationHeight: CGFloat = 40
}

/// Chrome appearance. Glass uses the native effect on iOS 26+; solid works on every supported OS.
public enum StreamSurfaceStyle: Sendable, Equatable { case glass, solid }

/// One policy for surfaces, button styles and glass grouping. Video never uses this helper.
enum StreamSurface {
    static func usesGlass(style: StreamSurfaceStyle, supported: Bool,
                          reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        style == .glass && supported && !reduceTransparency && !increasedContrast
    }
}

/// Reads accessibility settings dynamically, including changes while the view is mounted.
private struct StreamSurfacePolicy: DynamicProperty {
    @Environment(\.streamTheme) var theme
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    var usesGlass: Bool {
        let supported: Bool
        if #available(iOS 26, *) { supported = true } else { supported = false }
        return StreamSurface.usesGlass(style: theme.surfaceStyle, supported: supported,
                                       reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
    }
}

struct StreamSurfaceModifier<S: Shape>: ViewModifier {
    private var policy = StreamSurfacePolicy()
    let shape: S
    var fill: Color
    init(shape: S, fill: Color) { self.shape = shape; self.fill = fill }
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), policy.usesGlass {
            content.glassEffect(.regular.tint(fill), in: shape)
        } else {
            content.background(fill, in: shape)
                .overlay(shape.stroke(policy.theme.border, lineWidth: 1))
        }
    }
}

/// Place around chrome controls only, so a style/accessibility change cannot recreate the video.
struct StreamGlassGroup<Content: View>: View {
    private var policy = StreamSurfacePolicy()
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26, *), policy.usesGlass {
            GlassEffectContainer(spacing: 8) { content }
        } else { content }
    }
}

struct StreamChromeButton: ViewModifier {
    private var policy = StreamSurfacePolicy()
    enum Kind: Equatable { case primary, outline, navigation }
    let kind: Kind
    init(kind: Kind) { self.kind = kind }
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), policy.usesGlass {
            if kind == .primary {
                content.buttonStyle(.glassProminent).tint(policy.theme.primary)
                    .buttonBorderShape(.roundedRectangle(radius: policy.theme.buttonRadius))
                    .foregroundColor(policy.theme.primaryForeground)
            } else {
                content.buttonStyle(.glass).tint(policy.theme.accent)
                    .buttonBorderShape(.roundedRectangle(radius: policy.theme.buttonRadius))
                    .foregroundColor(kind == .navigation ? policy.theme.foreground : policy.theme.accentForeground)
            }
        } else if kind == .navigation {
            content.buttonStyle(StreamNavigationButtonStyle())
        } else {
            content.buttonStyle(StreamButtonStyle(outline: kind == .outline))
        }
    }
}
struct StreamNavigationButtonStyle: ButtonStyle {
    @Environment(\.streamTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundColor(theme.foreground)
            .background(configuration.isPressed ? theme.muted : theme.background)
            .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius)).opacity(enabled ? 1 : 0.5)
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
            .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius).stroke(outline ? theme.border : .clear, lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
    }
}
#endif
