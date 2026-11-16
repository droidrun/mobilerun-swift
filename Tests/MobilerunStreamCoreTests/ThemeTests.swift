// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit
@testable import MobilerunStream
import Testing
import MobilerunStreamCore

@Suite @MainActor struct ThemeTests {
    @Test(arguments: [
        (nil, "wss://example.test/stream?token=embedded%2Bvalue&other=one%20two"),
        ("", "wss://example.test/stream?token=embedded%2Bvalue&other=one%20two"),
        ("a+b/c=d&e", "wss://example.test/stream?other=one%20two&token=a%2Bb/c%3Dd%26e"),
    ])
    func signallingTokenURL(token: String?, expected: String) throws {
        let credentials = StreamCredentials(url: URL(string: "wss://example.test/stream?token=embedded%2Bvalue&other=one%20two")!, token: token)
        #expect(try URLSessionSignalling.endpoint(credentials).absoluteString == expected)
    }
    @Test func countdownStartsBeforeFirstTick() {
        let countdown = ApprovalCountdown(approvalId: "a", expiresAt: "2100-01-01T00:00:00Z")
        #expect(countdown.remaining > 0)
    }
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
    @Test func themeEqualityAndSeparateLabels() {
        #expect(StreamTheme.light == StreamTheme())
        #expect(StreamTheme.light != .dark)
        #expect(StreamTheme.light != StreamTheme.light.with { $0.surfaceStyle = .solid })
        #expect(StreamTheme.light.typography == .subheadline)
        var environment = EnvironmentValues()
        environment.streamLabels = StreamLabels(connecting: "Loading")
        environment.taskApprovalLabels = TaskApprovalLabels(approve: "Allow")
        #expect(environment.streamLabels.connecting == "Loading")
        #expect(environment.taskApprovalLabels.approve == "Allow")
    }
    @Test func lifecycleRebindUsesCurrentSession() async {
        let first = LifecycleRequests(), second = LifecycleRequests()
        let a = DeviceStreamSession(credentials: { await first.fetch() })
        let b = DeviceStreamSession(credentials: { await second.fetch() })
        defer { a.close(); b.close() }
        a.start(); b.start()
        await settle { first.count == 1 && second.count == 1 }
        let lifecycle = StreamLifecycleAdapter(session: a)
        lifecycle.start()
        lifecycle.rebind(session: b)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await drain()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle { second.count == 2 }
        #expect(first.count == 1)
        lifecycle.stop()
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
        #expect(light.radius == 8)
    }
}
@MainActor private final class LifecycleRequests {
    var count = 0
    func fetch() -> StreamCredentials? { count += 1; return nil }
}
#endif
