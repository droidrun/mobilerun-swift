import XCTest

// Keep simulator URL confirmation handling out of the streaming app.
final class URLConsent: XCTestCase {
    @MainActor func testAllowDebugURLs() {
        continueAfterFailure = false
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            let button = system.buttons["Open"]
            if button.exists { button.tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
