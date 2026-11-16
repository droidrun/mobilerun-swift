// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI

/// React CSS tokens converted once from OKLCH to gamma-encoded sRGB (CSS Color 4, gamut clamped).
/// Light is the default; follow the system only by explicitly opting in.
public struct StreamTheme: Equatable, StreamCustomizable {
    public var background: Color
    public var foreground: Color
    public var card: Color
    public var cardForeground: Color
    public var muted: Color
    public var mutedForeground: Color
    public var border: Color
    public var ring: Color
    public var primary: Color
    public var primaryForeground: Color
    public var accent: Color
    public var accentForeground: Color
    public var destructive: Color
    public var radius: CGFloat
    var buttonRadius: CGFloat { radius * 0.75 }
    var cardRadius: CGFloat { radius + 4 }
    public var typography: Font
    public var surfaceStyle: StreamSurfaceStyle
    public init(
        background: Color = Color(.sRGB, red: 1.00000000, green: 1.00000000, blue: 1.00000000, opacity: 1),
        foreground: Color = Color(.sRGB, red: 0.03938824, green: 0.03938823, blue: 0.03938823, opacity: 1),
        card: Color = Color(.sRGB, red: 1.00000000, green: 1.00000000, blue: 1.00000000, opacity: 1),
        cardForeground: Color = Color(.sRGB, red: 0.03938824, green: 0.03938823, blue: 0.03938823, opacity: 1),
        muted: Color = Color(.sRGB, red: 0.96058699, green: 0.96058699, blue: 0.96058699, opacity: 1),
        mutedForeground: Color = Color(.sRGB, red: 0.45151924, green: 0.45151924, blue: 0.45151924, opacity: 1),
        border: Color = Color(.sRGB, red: 0.89816066, green: 0.89816066, blue: 0.89816066, opacity: 1),
        ring: Color = Color(.sRGB, red: 0.63016320, green: 0.63016320, blue: 0.63016320, opacity: 1),
        primary: Color = Color(.sRGB, red: 0.09052741, green: 0.09052741, blue: 0.09052741, opacity: 1),
        primaryForeground: Color = Color(.sRGB, red: 0.98025598, green: 0.98025598, blue: 0.98025598, opacity: 1),
        accent: Color = Color(.sRGB, red: 0.96058699, green: 0.96058699, blue: 0.96058699, opacity: 1),
        accentForeground: Color = Color(.sRGB, red: 0.09052741, green: 0.09052741, blue: 0.09052741, opacity: 1),
        destructive: Color = Color(.sRGB, red: 0.90645756, green: 0.00000000, blue: 0.04221455, opacity: 1),
        radius: CGFloat = 8, typography: Font = .subheadline,
        surfaceStyle: StreamSurfaceStyle = .glass
    ) {
        self.background = background
        self.foreground = foreground
        self.card = card
        self.cardForeground = cardForeground
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.border = border
        self.ring = ring
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.accent = accent
        self.accentForeground = accentForeground
        self.destructive = destructive
        self.radius = radius; self.typography = typography; self.surfaceStyle = surfaceStyle
    }
    public static var light: Self { Self() }
    public static var dark: Self { Self(
        background: Color(.sRGB, red: 0.03938824, green: 0.03938823, blue: 0.03938823, opacity: 1),
        foreground: Color(.sRGB, red: 0.98025598, green: 0.98025598, blue: 0.98025598, opacity: 1),
        card: Color(.sRGB, red: 0.09052741, green: 0.09052741, blue: 0.09052741, opacity: 1),
        cardForeground: Color(.sRGB, red: 0.98025598, green: 0.98025598, blue: 0.98025598, opacity: 1),
        muted: Color(.sRGB, red: 0.14938208, green: 0.14938208, blue: 0.14938208, opacity: 1),
        mutedForeground: Color(.sRGB, red: 0.63016320, green: 0.63016320, blue: 0.63016320, opacity: 1),
        border: Color(.sRGB, red: 1.00000000, green: 1.00000000, blue: 1.00000000, opacity: 0.1),
        ring: Color(.sRGB, red: 0.45151924, green: 0.45151924, blue: 0.45151924, opacity: 1),
        primary: Color(.sRGB, red: 0.98025598, green: 0.98025598, blue: 0.98025598, opacity: 1),
        primaryForeground: Color(.sRGB, red: 0.09052741, green: 0.09052741, blue: 0.09052741, opacity: 1),
        accent: Color(.sRGB, red: 0.14938208, green: 0.14938208, blue: 0.14938208, opacity: 1),
        accentForeground: Color(.sRGB, red: 0.98025598, green: 0.98025598, blue: 0.98025598, opacity: 1),
        destructive: Color(.sRGB, red: 1.00000000, green: 0.39115272, blue: 0.40385680, opacity: 1)
    ) }
}
private struct StreamThemeKey: EnvironmentKey { static var defaultValue: StreamTheme { .light } }
public extension EnvironmentValues {
    var streamTheme: StreamTheme {
        get { self[StreamThemeKey.self] } set { self[StreamThemeKey.self] = newValue }
    }
}
private struct SystemStreamTheme: ViewModifier {
    let light: StreamTheme
    let dark: StreamTheme
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.streamTheme, scheme == .dark ? dark : light)
    }
}
public extension View {
    func streamTheme(_ theme: StreamTheme) -> some View { environment(\.streamTheme, theme) }
    func streamThemeFollowsSystem(light: StreamTheme = .light, dark: StreamTheme = .dark) -> some View {
        modifier(SystemStreamTheme(light: light, dark: dark))
    }
}
#endif
