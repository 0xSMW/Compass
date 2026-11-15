import XCTest
import CompassCore

/// Keyboard screens on a 667pt phone (iPhone SE): the lifted action must sit above the keyboard and
/// clear the field. CI runs this on an iPhone SE simulator with `SMALL_SCREENS=A4k,B5,C10`
/// (`TEST_RUNNER_SMALL_SCREENS`) and saves `<ID>.png` to `SCREENSHOT_DIR`; elsewhere it is skipped.
final class SmallScreenKeyboardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The action's accessibility label per screen, and whether it is separate from the field
    /// (C10's save button sits inside the note field's row).
    private let actions: [String: (labels: [String], separateFromField: Bool)] = [
        "A4k": (["Continue"], true),
        "B5": (["Add step", "Save"], true),
        "C10": (["Save note", "Save step"], false),
    ]

    @MainActor
    func testKeyboardScreensFitOnSmallScreens() throws {
        let env = ProcessInfo.processInfo.environment
        let ids = (env["SMALL_SCREENS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw XCTSkip("Set SMALL_SCREENS (TEST_RUNNER_SMALL_SCREENS) to run on a small simulator") }
        let output = URL(fileURLWithPath: env["SCREENSHOT_DIR"] ?? NSTemporaryDirectory() + "CompassSmallScreens", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for raw in ids {
            guard let id = ScreenID(rawValue: raw) else { XCTFail("\(raw): unknown screen"); continue }
            let app = XCUIApplication()
            app.launchArguments = ["-screen", id.rawValue, "-uitest"]
            app.launch()
            let marker = app.descendants(matching: .any)["screen-\(id.rawValue)"]
            if !marker.waitForExistence(timeout: 10) {
                XCTFail("\(id.rawValue): accessibility marker screen-\(id.rawValue) not found")
            }
            Thread.sleep(forTimeInterval: 0.6)
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(id.rawValue) small"
            attachment.lifetime = .keepAlways
            add(attachment)
            try? shot.pngRepresentation.write(to: output.appendingPathComponent("\(id.rawValue).png"))

            let window = app.windows.firstMatch.frame
            // Same estimate as ScreenMetrics.estimatedKeyboardHeight (Home-button phones: 260).
            let keyboardTop = window.maxY - (window.height < 700 ? 260 : 336)
            let field = (app.textViews.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
                .first { $0.exists && $0.frame.height > 0 }
            let spec = actions[id.rawValue] ?? ([], true)
            let action = spec.labels.lazy.map { app.buttons[$0] }.first { $0.exists }

            guard let field else { XCTFail("\(id.rawValue): no text field"); app.terminate(); continue }
            XCTAssertLessThanOrEqual(field.frame.maxY, keyboardTop + 0.5, "\(id.rawValue): field runs under the keyboard (\(field.frame))")
            if let action {
                XCTAssertLessThanOrEqual(action.frame.maxY, keyboardTop + 0.5, "\(id.rawValue): action under the keyboard (\(action.frame))")
                if spec.separateFromField {
                    XCTAssertFalse(action.frame.intersects(field.frame),
                                   "\(id.rawValue): action \(action.frame) overlaps the field \(field.frame)")
                }
            } else {
                XCTFail("\(id.rawValue): action button \(spec.labels) not found")
            }
            app.terminate()
        }
    }
}
