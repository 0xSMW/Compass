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
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-tapthrough"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: Helpers

    private func marker(_ id: String) -> XCUIElement { app.descendants(matching: .any)["screen-\(id)"] }

    /// The screen currently up, from its marker (for failure messages).
    private var currentScreen: String {
        let ids = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'screen-'"))
            .allElementsBoundByIndex.map(\.identifier)
        return ids.first ?? "none"
    }

    private func expectScreen(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if !marker(id).waitForExistence(timeout: timeout) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "stuck before \(id)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("Expected \(id), still on \(currentScreen)", file: file, line: line)
        }
    }

    private func button(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let b = app.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), "No “\(label)” button on \(currentScreen)", file: file, line: line)
        return b
    }

    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        button(label, file: file, line: line).tap()
    }

    /// A listening screen saves on silence; if it is still up after a moment, tap its stop button.
    private func finishListening(on listening: String, stop: String, next: String, file: StaticString = #filePath, line: UInt = #line) {
        if marker(next).waitForExistence(timeout: 4) { return }
        XCTAssertTrue(marker(listening).exists, "Expected \(listening) or \(next), on \(currentScreen)", file: file, line: line)
        if app.buttons[stop].exists { app.buttons[stop].firstMatch.tap() }
        expectScreen(next, file: file, line: line)
    }

    /// Type into the focused (or first) text view of the screen.
    private func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No text field on \(currentScreen)", file: file, line: line)
        field.tap()
        field.typeText(text)
    }

    // MARK: The day

    @MainActor
    func testOnboardingMorningNoteEvening() {
        // A · Onboarding: the goal by voice (the fake transcriber says the board's goal).
        expectScreen("A1")
        tap("Begin")
        expectScreen("A2")
        tap("Say your goal")
        finishListening(on: "A3", stop: "Stop", next: "A4")
        tap("Continue")
        expectScreen("A5")
        tap("Continue")
        expectScreen("A6")
        tap("Allow notifications")
        expectScreen("A7")
        tap("Start")

        // B · The first morning (08:00): skip the intention, name and type the step.
        expectScreen("B1")
        tap("Skip")
        expectScreen("B4")
        tap("Type instead")
        expectScreen("B5")
        type("Call Lena about the pilot")
        tap("Add step")

        // C · Today, with a typed note.
        expectScreen("C3")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Call Lena about the pilot"))
            .firstMatch.waitForExistence(timeout: 5), "Today shows the step")
        tap("Type a note")
        type("Ask Sam about Friday")
        tap("Save note")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Ask Sam about Friday"))
            .firstMatch.waitForExistence(timeout: 5), "the note is on Today (\(currentScreen))")
        expectScreen("C3")

        // D · 21:05: the evening comes in by the clock; Done, said, saved.
        app.buttons["tapthrough-evening"].firstMatch.tap()
        expectScreen("D1")
        tap("Done")
        // D3 listens (it may save on silence before the marker is seen), then D5 shows what was saved.
        finishListening(on: "D3", stop: "Stop and save", next: "D5")
    }
}
