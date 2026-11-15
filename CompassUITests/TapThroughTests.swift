import XCTest

/// One day through the live flow on the fakes (`-tapthrough`: empty in-memory store, fake recorder,
/// transcriber and cloud help, the fixtures' calendar, a clock starting at 08:00 that the test moves):
///
/// A1 → A2 → (goal said) A3 → A4 → A5 → A6 → A7 → B1 → (skip the intention) B4 → B5 (step typed) →
/// C3 (Today) → C10 (note typed) → C3 → 21:05 → D1 → Done → D3 (said) → D5.
///
/// Every hop waits for the next screen's `screen-<ID>` marker, so any broken hop fails the test with
/// the screen it was stuck on. CI runs it on the 390×844 simulator.
final class TapThroughTests: XCTestCase {
    @MainActor
    func testOnboardingMorningNoteEvening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tapthrough"]
        app.launch()
        defer { app.terminate() }
        let d = TapDriver(app: app, test: self)

        // A · Onboarding: the goal by voice (the fake transcriber says the board's goal).
        d.expectScreen("A1")
        d.tap("Begin")
        d.expectScreen("A2")
        d.tap("Say your goal")
        d.finishListening(on: "A3", stop: "Stop", next: "A4")
        d.tap("Continue")
        d.expectScreen("A5")
        d.tap("Continue")
        d.expectScreen("A6")
        d.tap("Allow notifications")
        d.expectScreen("A7")
        d.tap("Start")

        // B · The first morning (08:00): skip the intention, name and type the step.
        d.expectScreen("B1")
        d.tap("Skip")
        d.expectScreen("B4")
        d.tap("Type instead")
        d.expectScreen("B5")
        d.type("Call Lena about the pilot")
        d.tap("Add step")

        // C · Today, with a typed note.
        d.expectScreen("C3")
        d.expectText("Call Lena about the pilot", "Today shows the step")
        d.tap("Type a note")
        d.type("Ask Sam about Friday")
        d.tap("Save note")
        d.expectText("Ask Sam about Friday", "the note is on Today")
        d.expectScreen("C3")

        // D · 21:05: the evening comes in by the clock; Done, said, saved.
        app.buttons["tapthrough-evening"].firstMatch.tap()
        d.expectScreen("D1")
        d.tap("Done")
        // D3 listens (it may save on silence before its marker is seen), then D5 shows what was saved.
        d.finishListening(on: "D3", stop: "Stop and save", next: "D5")
    }
}

/// Taps and waits on the main actor (XCUIElement is main-actor isolated).
@MainActor
private struct TapDriver {
    let app: XCUIApplication
    let test: XCTestCase

    func marker(_ id: String) -> XCUIElement { app.descendants(matching: .any)["screen-\(id)"] }

    /// The screen currently up, from its marker (for failure messages).
    var currentScreen: String {
        let markers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'screen-'"))
        return markers.firstMatch.exists ? markers.firstMatch.identifier : "none"
    }

    func expectScreen(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard !marker(id).waitForExistence(timeout: timeout) else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "stuck before \(id)"
        shot.lifetime = .keepAlways
        test.add(shot)
        XCTFail("Expected \(id), still on \(currentScreen)", file: file, line: line)
    }

    func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "No “\(label)” button on \(currentScreen)", file: file, line: line)
        button.tap()
    }

    func expectText(_ text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(message) (on \(currentScreen))", file: file, line: line)
    }

    /// A listening screen saves on silence; if it is still up after a moment, tap its stop button.
    func finishListening(on listening: String, stop: String, next: String, file: StaticString = #filePath, line: UInt = #line) {
        if marker(next).waitForExistence(timeout: 4) { return }
        XCTAssertTrue(marker(listening).exists, "Expected \(listening) or \(next), on \(currentScreen)", file: file, line: line)
        let button = app.buttons[stop].firstMatch
        if button.exists { button.tap() }
        expectScreen(next, file: file, line: line)
    }

    /// Type into the screen's text field once it has keyboard focus (tapping it again if needed).
    func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No text field on \(currentScreen)", file: file, line: line)
        let focused = app.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        for _ in 0..<3 where !focused.exists {
            field.tap()
            _ = focused.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(focused.exists, "The text field on \(currentScreen) never took keyboard focus", file: file, line: line)
        focused.typeText(text)
    }
}
