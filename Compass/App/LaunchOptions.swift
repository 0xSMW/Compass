import Foundation
import CompassCore

/// Launch-argument harness (Debug builds only; a Release build ignores every argument and runs live).
///
/// - `-screen <ID>`: open straight into that screen's fixture state (`Fixtures.fixture(for:)`), with an
///   in-memory store and fake services. IDs are the board IDs: `A4k`, `C11b`, `D1L` (case-insensitive).
/// - `-variant <name>`: with `-screen`, a state the boards don't draw (`ScreenVariant`): the A1 restore
///   question, the H1 "Reminders" row. Screenshot extras only.
/// - `-ax5`: force the largest accessibility text size. Implied for the "largest" states
///   (A8, B8, C11, C11b, D7, D8, E6).
/// - `-uitest`: deterministic rendering for screenshots (motion reduced, no persistence).
/// - `-tapthrough`: the live flow from A1 on fakes, an in-memory store and a movable clock, for the
///   tap-through UI test (`TapThroughTests`). Implies `-uitest`.
///
/// As the host of the `CompassTests` unit tests (no `-screen`), the app opens on a fixture so it never
/// touches the real store, iCloud or notifications; the tests build their own `AppModel`s.
///
/// The fields exist in every configuration (views read them), but only Debug can set them: in Release
/// `parse()` returns the defaults, and `LaunchHarness` (the fixture and fake wiring), the tap-through
/// clock and its control are compiled out. CI builds Release and checks the binary for them.
struct LaunchOptions: Equatable {
    var screen: ScreenID?
    var forceAX5: Bool = false
    var uiTest: Bool = false
    var tapThrough: Bool = false
    var variant: ScreenVariant?

    static func parse(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        #if DEBUG
        var options = LaunchOptions()
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "-screen":
                if i + 1 < arguments.count {
                    options.screen = ScreenID(argument: arguments[i + 1])
                    if options.screen == nil { print("Compass launch harness: unknown -screen ID \(arguments[i + 1])") }
                    i += 1
                }
            case "-variant":
                if i + 1 < arguments.count { options.variant = ScreenVariant(rawValue: arguments[i + 1]); i += 1 }
            case "-ax5":
                options.forceAX5 = true
            case "-uitest":
                options.uiTest = true
            case "-tapthrough":
                options.tapThrough = true
                options.uiTest = true
            default:
                break
            }
            i += 1
        }
        if options.tapThrough { options.screen = nil }
        if options.screen == nil, !options.tapThrough, isUnitTestHost {
            options.screen = .c1
            options.uiTest = true
        }
        if options.screen == nil { options.variant = nil }
        if options.screen?.isLargestText == true { options.forceAX5 = true }
        return options
        #else
        return LaunchOptions()
        #endif
    }

    #if DEBUG
    /// True when XCTest injected a unit-test bundle into this process (hosted `CompassTests`).
    static var isUnitTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    #endif
}

/// `-variant`: a fixture screen in a state no board draws, for the screenshot extras
/// (`renders/ios/extra/`). Applied by `LaunchHarness` (Debug only).
enum ScreenVariant: String, Equatable {
    /// A1 with "Restore from iCloud?" up (a backup was found and Begin was tapped).
    case restoreChoice = "restore-choice"
    /// H1 with the "Reminders · Off" row (reminders off after "Not now", or not allowed by iOS).
    case remindersOff = "reminders-off"
}
