import Foundation
import CompassCore

/// Launch-argument harness.
///
/// - `-screen <ID>`: open straight into that screen's fixture state (`Fixtures.fixture(for:)`), with an
///   in-memory store and fake services. IDs are the board IDs: `A4k`, `C11b`, `D1L` (case-insensitive).
/// - `-ax5`: force the largest accessibility text size. Implied for the "largest" states
///   (A8, B8, C11, C11b, D7, D8, E6).
/// - `-uitest`: deterministic rendering for screenshots (motion reduced, no persistence).
struct LaunchOptions: Equatable {
    var screen: ScreenID?
    var forceAX5: Bool = false
    var uiTest: Bool = false

    static func parse(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "-screen":
                if i + 1 < arguments.count { options.screen = ScreenID(argument: arguments[i + 1]); i += 1 }
            case "-ax5":
                options.forceAX5 = true
            case "-uitest":
                options.uiTest = true
            default:
                break
            }
            i += 1
        }
        if options.screen?.isLargestText == true { options.forceAX5 = true }
        return options
    }
}
