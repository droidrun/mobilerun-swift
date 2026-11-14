// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit
@testable import MobilerunStream
import Testing

@Suite @MainActor struct ThemeTests {
    @Test func surfaceStyleAndAccessibility() {
        #expect(StreamTheme().surfaceStyle == .glass)
        #expect(StreamTheme.light.surfaceStyle == .glass)
        #expect(StreamTheme.dark.surfaceStyle == .glass)
        #expect(StreamTheme.light.with { $0.surfaceStyle = .solid }.surfaceStyle == .solid)
        for supported in [false, true] {
            for reduce in [false, true] {
                for contrast in [false, true] {
                    for style: StreamSurfaceStyle in [.glass, .solid] {
                        #expect(StreamSurface.usesGlass(style: style, supported: supported,
                                                       reduceTransparency: reduce, increasedContrast: contrast) ==
                                (style == .glass && supported && !reduce && !contrast))
                    }
                }
            }
        }
    }
    @Test func reactDefaults() {
        // CSS Color 4 conversions, rounded to 8-bit sRGB. Alpha is checked separately.
        let light = StreamTheme.light, dark = StreamTheme.dark
        func channels(_ color: Color) -> [Int] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { Int(($0 * 255).rounded()) }
        }
        for (color, expected) in [
            (light.background, [255,255,255]), (light.foreground, [10,10,10]),
            (light.card, [255,255,255]), (light.cardForeground, [10,10,10]),
            (light.muted, [245,245,245]), (light.mutedForeground, [115,115,115]),
            (light.border, [229,229,229]), (light.ring, [161,161,161]),
            (light.primary, [23,23,23]), (light.primaryForeground, [250,250,250]),
            (light.accent, [245,245,245]), (light.accentForeground, [23,23,23]),
            (light.destructive, [231,0,11]),
            (dark.background, [10,10,10]), (dark.foreground, [250,250,250]),
            (dark.card, [23,23,23]), (dark.cardForeground, [250,250,250]),
            (dark.muted, [38,38,38]), (dark.mutedForeground, [161,161,161]),
            (dark.border, [255,255,255]), (dark.ring, [115,115,115]),
            (dark.primary, [250,250,250]), (dark.primaryForeground, [23,23,23]),
            (dark.accent, [38,38,38]), (dark.accentForeground, [250,250,250]),
            (dark.destructive, [255,100,103])
        ] { #expect(channels(color) == expected) }
        #expect(abs(UIColor(dark.border).cgColor.alpha - 0.1) < 0.000001)
        #expect(channels(EnvironmentValues().streamTheme.background) == [255,255,255])
        #expect(StreamTheme.light.with { $0.radius = 20 }.radius == 20)
        #expect(light.radius == 12)
    }
}
#endif
