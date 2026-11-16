import XCTest

/// Simulator banners (a fresh simulator posts "Ready for Apple Intelligence" soon after its first boot)
/// that would cover the top of a screenshot.
@MainActor
enum SystemBanners {
    private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private static var banner: XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'NotificationShortLookView' OR label CONTAINS[c] 'Apple Intelligence'"
        )).firstMatch
    }

    /// True when a banner is up.
    static var isShowing: Bool { banner.exists }

    /// Swipe away any banner over the screen and wait for it to go (up to `timeout`).
    static func dismiss(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while banner.exists, Date() < deadline {
            if banner.isHittable { banner.swipeUp() }
            _ = banner.waitForNonExistence(timeout: 2)
        }
    }
}
