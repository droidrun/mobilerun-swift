// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import XCTest
import UIKit

@MainActor final class InputUITests: XCTestCase {
    func testNativeTapAndHardwareKey() throws {
        let app = XCUIApplication(bundleIdentifier: "io.mobilerun.Connection")
        app.activate()
        XCTAssertTrue(app.staticTexts["connected"].waitForExistence(timeout: 45))
        let surface = app.otherElements["device-stream-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let size = try XCTUnwrap(surface.value as? String).split(separator: "x").compactMap { Double($0) }
        guard size.count == 4 else { XCTFail("video size or scenario target missing"); return }
        let frame = surface.frame
        let scale = min(frame.width / size[0], frame.height / size[1])
        let videoWidth = size[0] * scale
        let videoHeight = size[1] * scale
        // The external scenario supplies a fixed video-space target; no target selection occurs here.
        let x = (frame.width - videoWidth) / 2 + videoWidth * size[2]
        let y = (frame.height - videoHeight) / 2 + videoHeight * size[3]
        surface.coordinate(withNormalizedOffset: CGVector(dx: x / frame.width, dy: y / frame.height)).tap()
        let delivered = app.staticTexts["last-native-input"]
        expectation(for: NSPredicate(format: "label == %@", "touch"), evaluatedWith: delivered)
        waitForExpectations(timeout: 5)
        app.typeKey("x", modifierFlags: [])
        expectation(for: NSPredicate(format: "label == %@", "press"), evaluatedWith: delivered)
        waitForExpectations(timeout: 5)
    }
}

@MainActor final class DefaultUITests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--default-ui", "--ui-state", mode]
        app.launch()
        return app
    }
    private func captureSurface(_ app: XCUIApplication, name: String, width: CGFloat) {
        let surface = app.otherElements["device-stream-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertEqual(surface.frame.width, width, accuracy: 1)
        XCTAssertEqual(surface.frame.height, 720, accuracy: 1)
        let attachment = XCTAttachment(screenshot: surface.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testPublishLayoutNarrow() {
        let before = launch("publish-narrow-before")
        captureSurface(before, name: "publish-before-375", width: 375)
        XCTAssertFalse(before.buttons["stream-publish-microphone"].exists)
        before.terminate()
        let after = launch("publish-narrow-after")
        XCTAssertTrue(after.buttons["Stop microphone"].waitForExistence(timeout: 10))
        captureSurface(after, name: "publish-after-375", width: 375)
        after.terminate()
    }
    func testPublishLayoutWide() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "1280-point viewport requires iPad")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let before = launch("publish-wide-before")
        captureSurface(before, name: "publish-before-1280", width: 1280)
        XCTAssertFalse(before.buttons["stream-publish-microphone"].exists)
        before.terminate()
        let after = launch("publish-wide-after")
        XCTAssertTrue(after.buttons["Stop microphone"].waitForExistence(timeout: 10))
        captureSurface(after, name: "publish-after-1280", width: 1280)
        after.terminate()
    }
    func testPublishPillVisibilityAndClickThrough() {
        let absent = launch("connecting")
        XCTAssertTrue(absent.otherElements["device-stream-surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(absent.buttons["stream-publish-microphone"].exists)
        capture("publish-before")
        absent.terminate()
        let hidden = launch("publish-hidden")
        XCTAssertTrue(hidden.otherElements["device-stream-surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(hidden.buttons["stream-publish-microphone"].exists)
        hidden.terminate()
        let app = launch("publish-idle")
        XCTAssertTrue(app.buttons["stream-publish-microphone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["stream-publish-camera"].exists)
        capture("publish-after")
        app.buttons["stream-publish-microphone"].tap()
        // Offline demo has no connected transport: readiness fails before any protected capture API.
        XCTAssertTrue(app.staticTexts["Media publication could not start."].waitForExistence(timeout: 5))
        app.buttons["stream-publish-camera"].tap()
        XCTAssertTrue(app.staticTexts["Media publication could not start."].exists)
        app.terminate()
    }
    func testPublishPillStartingAndFailureLabels() {
        let starting = launch("publish-starting")
        XCTAssertTrue(starting.buttons["stream-publish-microphone"].waitForExistence(timeout: 10))
        XCTAssertFalse(starting.buttons["stream-publish-microphone"].isEnabled)
        XCTAssertFalse(starting.buttons["stream-publish-camera"].isEnabled)
        starting.terminate()
        let permission = launch("publish-permission")
        XCTAssertTrue(permission.staticTexts["Allow microphone and camera access in Settings."].waitForExistence(timeout: 10))
        capture("publish-permission")
        permission.terminate()
        let forbidden = launch("publish-forbidden")
        XCTAssertTrue(forbidden.staticTexts["Media publication is not allowed."].waitForExistence(timeout: 10))
        capture("publish-forbidden")
        forbidden.terminate()
        let active = launch("publish-active")
        XCTAssertTrue(active.buttons["Stop microphone"].waitForExistence(timeout: 10))
        XCTAssertTrue(active.buttons["Stop camera"].exists)
        capture("publish-active")
        active.terminate()
    }
    func testGlassSolidSwitchAndAccessibility() {
        let app = launch("approval-glass-switch")
        XCTAssertTrue(app.staticTexts["surface-style"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["surface-style"].label, "glass")
        XCTAssertTrue(app.buttons["Approve"].exists)
        capture("glass-default-light")
        app.buttons["Use solid"].tap()
        XCTAssertEqual(app.staticTexts["surface-style"].label, "solid")
        XCTAssertTrue(app.buttons["Approve"].isEnabled)
        capture("solid-override-light")
        app.buttons["Use glass"].tap()
        app.buttons["Use solid"].tap()
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.staticTexts["Decision sent: approve"].waitForExistence(timeout: 10))
        app.terminate()
    }
    func testGlassAccessibilityPreferences() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Native glass requires iOS 26") }
        let app = launch("approval-glass-switch")
        XCTAssertTrue(app.staticTexts["Effective surface: glass"].waitForExistence(timeout: 10))
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        // Settings rows expose a button with a text descendant on current iOS.
        let accessibility = settings.staticTexts["Accessibility"]
        for _ in 0..<5 {
            if accessibility.isHittable { break }
            settings.swipeUp()
        }
        accessibility.tap()
        settings.staticTexts["Display & Text Size"].tap()
        func set(_ name: String, enabled: Bool) {
            let toggle = settings.switches[name]
            for _ in 0..<5 {
                if toggle.isHittable { break }
                settings.swipeUp()
            }
            XCTAssertTrue(toggle.exists)
            let expected = enabled ? "1" : "0"
            for _ in 0..<2 {
                if toggle.value as? String == expected { return }
                // Current Settings exposes a row-sized switch containing the actual toggle.
                // Activation can return during its zoom transition; verify the change before leaving.
                let control = toggle.switches.firstMatch
                if control.exists { control.tap() }
                else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
                if XCTWaiter.wait(for: [changed], timeout: 3) == .completed { return }
            }
            XCTAssertEqual(toggle.value as? String, expected, toggle.debugDescription)
        }
        defer {
            settings.activate()
            set("Reduce Transparency", enabled: false)
            set("Increase Contrast", enabled: false)
            app.terminate()
        }
        set("Reduce Transparency", enabled: true)
        app.activate()
        XCTAssertTrue(app.staticTexts["Effective surface: solid"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Approve"].isEnabled)
        capture("glass-system-reduce-transparency")
        settings.activate()
        set("Reduce Transparency", enabled: false)
        set("Increase Contrast", enabled: true)
        app.activate()
        XCTAssertTrue(app.staticTexts["Effective surface: solid"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Approve"].isEnabled)
        capture("glass-system-increase-contrast")
        settings.activate()
        set("Increase Contrast", enabled: false)
        app.activate()
        XCTAssertTrue(app.staticTexts["Effective surface: glass"].waitForExistence(timeout: 10))
    }
    func testStreamStatesAndLabels() {
        let app = launch("connecting")
        XCTAssertTrue(app.staticTexts["connecting"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Back"].exists)
        app.terminate()
        _ = launch("unavailable")
        XCTAssertTrue(app.staticTexts["device stream unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Retry"].isEnabled)
        XCTAssertFalse(app.buttons["Back"].isEnabled)
        app.terminate()
        _ = launch("custom")
        XCTAssertTrue(app.staticTexts["Connecting your phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Go back"].exists)
        app.terminate()
        _ = launch("reconnecting-retained")
        XCTAssertTrue(app.staticTexts["reconnecting (3/6)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["stream-phone-placeholder"].exists)
        capture("reconnecting-retained-opaque-fixture")
        app.terminate()
    }
    func testApprovalExpiryDecisionRefetchAndDeviceIdentity() {
        let app = launch("approval-expired")
        XCTAssertTrue(app.staticTexts["Approval expired"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Approve"].isEnabled)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].waitForExistence(timeout: 10))
        capture("approval-expired-details")
        app.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        capture("approval-device")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        Thread.sleep(forTimeInterval: 1)
        capture("approval-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Details"].tap()
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.staticTexts["Decision sent: approve"].waitForExistence(timeout: 10))
        capture("approval-approved-refetch")
        app.terminate()
        _ = launch("approval")
        XCTAssertTrue(app.buttons["Deny"].waitForExistence(timeout: 10))
        capture("approval-countdown")
        app.buttons["Deny"].tap()
        XCTAssertTrue(app.staticTexts["Decision sent: deny"].waitForExistence(timeout: 10))
        capture("approval-denied-refetch")
        app.terminate()
    }
    func testApprovalLongDetailsAndNewId() {
        let app = launch("approval-long")
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 10))
        app.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        for _ in 0..<5 {
            if app.buttons["Next approval"].isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2)))
        }
        app.buttons["Next approval"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8)))
        XCTAssertTrue(app.staticTexts["Card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        XCTAssertGreaterThanOrEqual(app.staticTexts["Card"].frame.minY, app.buttons["Details"].frame.maxY)
        let facts = app.scrollViews["approval-details"]
        XCTAssertGreaterThanOrEqual(app.buttons["Approve"].frame.minY, facts.frame.maxY)
        for _ in 0..<5 {
            if app.buttons["Approve"].isHittable && app.buttons["Approve"].frame.maxY < app.frame.maxY - 30 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2)))
        }
        XCTAssertTrue(app.buttons["Approve"].isHittable)
        capture("approval-long-dynamic-type-actions")
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.staticTexts["Decision sent: approve"].waitForExistence(timeout: 10))
        app.terminate()
    }
    func testApprovalCardWidthBreakpoint() throws {
        let app = launch("approval-boundary")
        guard app.frame.width >= 768 else { app.terminate(); throw XCTSkip("Requires a wide container") }
        XCTAssertTrue(app.staticTexts["Card"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Device"].exists) // 768 includes card padding.
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        capture("approval-width-768")
        app.buttons["Toggle breakpoint"].tap()
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 10))
        capture("approval-width-767")
        app.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        app.buttons["Toggle breakpoint"].tap()
        XCTAssertFalse(app.buttons["Device"].exists)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        app.terminate()
    }
    func testApprovalAdaptiveWidth() throws {
        let app = launch("approval-resize")
        guard app.frame.width >= 768 else { app.terminate(); throw XCTSkip("Requires a wide container") }
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Card"].exists)
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        capture("approval-wide")
        app.buttons["Resize layout"].tap()
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        capture("approval-narrow")
        app.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        app.buttons["Resize layout"].tap()
        XCTAssertTrue(app.staticTexts["Card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["connecting"].exists)
        XCTAssertFalse(app.buttons["Device"].exists)
        XCTAssertTrue(app.staticTexts["Device mounts: 1"].exists)
        capture("approval-wide-again")
        app.terminate()
    }
    func testApprovalErrorRetainsActions() {
        let app = launch("approval-error")
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 10))
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.staticTexts["The decision could not be sent. Try again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Deny"].isEnabled)
        capture("approval-error")
        app.terminate()
    }
}

@MainActor final class SampleUITests: XCTestCase {
    func testApprovalCountdownDecisionsRefetchAndTheme() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.secureTextFields["stream-token"].waitForExistence(timeout: 10))
        app.buttons["Demo approval"].tap()
        XCTAssertTrue(app.staticTexts["Visa 4242"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.staticTexts["Decision: approve · refetch 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Approve"].waitForNonExistence(timeout: 5))
        app.buttons["Demo approval"].tap()
        XCTAssertTrue(app.buttons["Deny"].waitForExistence(timeout: 5))
        app.buttons["Deny"].tap()
        XCTAssertTrue(app.staticTexts["Decision: deny · refetch 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Deny"].waitForNonExistence(timeout: 5))
        let solid = app.switches["solid-chrome"].firstMatch
        for theme in ["Light", "Dark", "Brand"] {
            app.buttons[theme].tap()
            solid.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(solid.value as? String, "1")
            solid.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(solid.value as? String, "0")
        }
        solid.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.buttons["Demo approval"].tap()
        XCTAssertTrue(app.buttons["Allow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Decline"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sample-brand-approval-solid"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
