import SwiftUI

/// Spacing on the 8pt grid. 24 is the default gap, inset and card padding;
/// 8–16 inside a group; 32–48 between groups.
enum Space {
    static let xs: CGFloat = 8
    static let s: CGFloat = 16
    static let m: CGFloat = 24
    static let l: CGFloat = 32
    static let xl: CGFloat = 48
    /// Screen side inset.
    static let inset: CGFloat = 24
}

/// Corner radii. Pill = height ÷ 2.
enum Radius {
    /// Cards, sheets (top), player, notices, widgets, option cards.
    static let card: CGFloat = 24
    /// Tiles and fields.
    static let tile: CGFloat = 12
    /// Sheet bottom corners (follow the device).
    static let sheetBottom: CGFloat = 48
    static func pill(_ height: CGFloat) -> CGFloat { height / 2 }
}

/// Control sizes. 44 minimum target; 56 keyboard, completion, secondary voice; 96 voice and answers.
enum ControlSize {
    static let minTarget: CGFloat = 44
    static let secondary: CGFloat = 56
    static let voice: CGFloat = 96
    /// Choice circles at accessibility sizes become 72pt-tall full-width buttons.
    static let accessibleChoice: CGFloat = 72
    static let button: CGFloat = 56
    static let notePill: CGFloat = 64
    static let player: CGFloat = 80
}

/// Icon sizes from kit.css (svg.xs / .s / .i / .m / .l).
enum IconSize {
    static let xs: CGFloat = 16
    static let s: CGFloat = 20
    static let i: CGFloat = 24
    static let m: CGFloat = 28
    static let l: CGFloat = 36
}

/// Motion and sound from the system sheet. Every animation has a reduced variant.
enum Motion {
    /// Center rings expand 4 s, settle 4 s. Reduced: still.
    static let breath: Double = 4
    /// Question, prompt and summary cross-fade in place. Reduced: cut.
    static let turnTaking: Double = 0.2
    /// The tapped circle becomes the mic on the same line. Reduced: cut.
    static let answerToRecord: Double = 0.24
    /// Completion circle fills from centre. Reduced: instant.
    static let complete: Double = 0.24

    static func animation(_ duration: Double, reduced: Bool) -> Animation? {
        reduced ? nil : .easeInOut(duration: duration)
    }
}

private struct MotionReducedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Reduce Motion, or forced on for screenshot runs (`-uitest`). Read this instead of
    /// `accessibilityReduceMotion` so screenshots are deterministic.
    var motionReduced: Bool {
        get { self[MotionReducedKey.self] }
        set { self[MotionReducedKey.self] = newValue }
    }
}
