import XCTest
import CompassCore

/// Launches every ScreenID with `-screen <ID> -uitest` and saves a PNG named `<ID>.png`.
///
/// Output: `$SCREENSHOT_DIR` (set `TEST_RUNNER_SCREENSHOT_DIR` on the xcodebuild command line), else the
/// test's temporary directory. Each image is also attached to the result bundle.
/// One test per flow so a failure names the flow; `continueAfterFailure` keeps going.
/// A screen whose `screen-<ID>` accessibility marker is missing fails its flow's test.
///
/// `testZ_Extras` adds states no board draws (`-variant`, see `ScreenVariant`) at Large and AX5, saved to
/// `extra/<name>.png` beside the 66 (`renders/ios/extra/`). They run only when no `SCREENS` filter is set.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let path = env["SCREENSHOT_DIR"] ?? NSTemporaryDirectory() + "CompassScreenshots"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var filter: Set<String>? {
        // Optional filter: SCREENS="C3,C4" (TEST_RUNNER_SCREENS in CI). Empty = all.
        let ids = (ProcessInfo.processInfo.environment["SCREENS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : Set(ids)
    }

    @MainActor
    private func capture(_ ids: [ScreenID]) {
        let only = filter
        for id in ids where only?.contains(id.rawValue) ?? true {
            shoot(id, ax5: id.isLargestText, name: id.rawValue)
        }
    }

    /// Launch `id` (with `variant`, at AX5 if asked), wait for its marker and save `<name>.png`.
    @MainActor
    private func shoot(_ id: ScreenID, variant: String? = nil, ax5: Bool, name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", id.rawValue, "-uitest"]
        if let variant { app.launchArguments += ["-variant", variant] }
        if ax5 { app.launchArguments.append("-ax5") }
        app.launch()
        let marker = app.descendants(matching: .any)["screen-\(id.rawValue)"]
        // The screen must say which ID it is drawing: a missing marker means the wrong screen (or none)
        // rendered, so the test fails. The screenshot is still taken to show what came up instead.
        if !marker.waitForExistence(timeout: 10) {
            XCTFail("\(name): accessibility marker screen-\(id.rawValue) not found")
        }
        // Let fonts, layout and any first-frame work settle; no simulator banner over the top.
        Thread.sleep(forTimeInterval: 0.6)
        SystemBanners.dismiss()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("\(name): could not write \(url.path): \(error)")
        }
        app.terminate()
    }

    @MainActor func testA_Onboarding() { capture(Flow.onboarding.screens) }
    @MainActor func testB_Morning() { capture(Flow.morning.screens) }
    @MainActor func testC_Today() { capture(Flow.today.screens) }
    @MainActor func testD_Evening() { capture(Flow.evening.screens) }
    @MainActor func testE_History() { capture(Flow.history.screens) }
    @MainActor func testF_Return() { capture(Flow.lapse.screens) }
    @MainActor func testG_Goal() { capture(Flow.goal.screens) }
    @MainActor func testH_Settings() { capture(Flow.settings.screens) }
    @MainActor func testI_System() { capture(Flow.system.screens) }

    /// States no board draws, at Large and AX5: A1's "Restore from iCloud?" sheet (three actions in 376pt)
    /// and H1 with the "Reminders" row. Each must show its actions on screen, none clipped.
    @MainActor func testZ_Extras() throws {
        guard filter == nil else { throw XCTSkip("Extras run only without a SCREENS filter") }
        let extras: [(ScreenID, String, String, [String])] = [
            (.a1, "restore-choice", "A1-restore-choice", ["label == 'Restore'", "label == 'Start a new goal'", "label == 'Cancel'"]),
            (.h1, "reminders-off", "H1-reminders", ["identifier == 'settings-reminders'"]),
        ]
        for (id, variant, name, controls) in extras {
            for ax5 in [false, true] {
                let fullName = name + (ax5 ? "-ax5" : "")
                shoot(id, variant: variant, ax5: ax5, name: "extra/\(fullName)")
                // Relaunch to check the controls (shoot terminated the app after the shot).
                let app = XCUIApplication()
                app.launchArguments = ["-screen", id.rawValue, "-uitest", "-variant", variant] + (ax5 ? ["-ax5"] : [])
                app.launch()
                let screen = app.windows.firstMatch.frame
                for query in controls {
                    let control = app.descendants(matching: .any).matching(NSPredicate(format: query)).firstMatch
                    let label = query
                    guard control.waitForExistence(timeout: 5) else {
                        XCTFail("\(fullName): no control with \(label)"); continue
                    }
                    XCTAssertTrue(screen.contains(control.frame), "\(fullName): “\(label)” runs off the screen (\(control.frame))")
                    XCTAssertTrue(control.isHittable, "\(fullName): “\(label)” isn't hittable (\(control.frame))")
                }
                app.terminate()
            }
        }
    }
}
