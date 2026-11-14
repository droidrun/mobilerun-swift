// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import XCTest

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
            if (toggle.value as? String == "1") != enabled {
                // The Settings accessibility element spans the row; hit the trailing switch.
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0", toggle.debugDescription)
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
