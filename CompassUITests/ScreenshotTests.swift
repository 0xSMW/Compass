import XCTest
import CompassCore

/// Launches every ScreenID with `-screen <ID> -uitest` and saves a PNG named `<ID>.png`.
///
/// Output: `$SCREENSHOT_DIR` (set `TEST_RUNNER_SCREENSHOT_DIR` on the xcodebuild command line), else the
/// test's temporary directory. Each image is also attached to the result bundle.
/// One test per flow so a failure names the flow; `continueAfterFailure` keeps going.
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

    private func capture(_ ids: [ScreenID]) {
        // Optional filter: SCREENS="C3,C4" (TEST_RUNNER_SCREENS in CI). Empty = all.
        let filter = (ProcessInfo.processInfo.environment["SCREENS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let only: Set<String>? = filter.isEmpty ? nil : Set(filter)
        for id in ids where only?.contains(id.rawValue) ?? true {
            let app = XCUIApplication()
            app.launchArguments = ["-screen", id.rawValue, "-uitest"]
            if id.isLargestText { app.launchArguments.append("-ax5") }
            app.launch()
            let marker = app.descendants(matching: .any)["screen-\(id.rawValue)"]
            if !marker.waitForExistence(timeout: 10) {
                XCTContext.runActivity(named: "\(id.rawValue): marker not found, capturing anyway") { _ in }
            }
            // Let fonts, layout and any first-frame work settle.
            Thread.sleep(forTimeInterval: 0.6)
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = id.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = outputDirectory.appendingPathComponent("\(id.rawValue).png")
            do {
                try shot.pngRepresentation.write(to: url)
            } catch {
                XCTFail("\(id.rawValue): could not write \(url.path): \(error)")
            }
            app.terminate()
        }
    }

    func testA_Onboarding() { capture(Flow.onboarding.screens) }
    func testB_Morning() { capture(Flow.morning.screens) }
    func testC_Today() { capture(Flow.today.screens) }
    func testD_Evening() { capture(Flow.evening.screens) }
    func testE_History() { capture(Flow.history.screens) }
    func testF_Return() { capture(Flow.lapse.screens) }
    func testG_Goal() { capture(Flow.goal.screens) }
    func testH_Settings() { capture(Flow.settings.screens) }
    func testI_System() { capture(Flow.system.screens) }
}
