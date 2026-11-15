import Foundation
import CompassCore

/// The entry screen follows the clock, from any screen (live path).
///
/// Each time the app becomes active, the device clock or time zone changes, or the boundary timer fires
/// (noon, the evening time, midnight; `SystemServices` keeps it armed), the screen is judged again:
/// if the day or the part of the day moved on since the last look, the morning, Today, evening or
/// return screen at the root is replaced by the new entry screen. History or Settings pushed on top
/// stay where they are, with the right screen under them. While something is being said or typed
/// the move waits, and the answer saves to the day it was given for (`EveningSession.dayKey`).
extension AppModel {
    enum ClockRefresh: Equatable {
        /// Same day, same part of the day (or a screen the clock doesn't own).
        case unchanged
        /// The root screen was replaced by the new entry screen.
        case moved
        /// The clock moved, but an answer is being said or typed; look again shortly.
        case deferred
    }

    /// Flows that belong to one part of the day. Onboarding, Goal, History and Settings screens are
    /// never pulled away by the clock.
    private static let dayFlows: Set<Flow> = [.morning, .today, .evening, .lapse]

    /// Something is being said, typed or saved right now.
    var isMidAnswer: Bool {
        if isComposing || current == .b5 { return true }
        if voice.isBusy { return true }
        let evening = eveningSession
        return evening.typing || evening.editingSummary || evening.working
    }

    /// Judge the screen against the clock. Both moments are judged on today's data, so saving an
    /// intention or a step (which changes the phase by itself) never counts as the clock moving.
    @discardableResult
    func refreshEntryForClock() -> ClockRefresh {
        let now = self.now
        guard let then = entryCheckedAt else {
            entryCheckedAt = now
            return .unchanged
        }
        guard DayEngine(calendar: calendar).clockMoved(from: then, to: now, snapshot: snapshot),
              let root = path.first, Self.dayFlows.contains(root.flow) else {
            entryCheckedAt = now
            return .unchanged
        }
        // Keep `then`: once the answer is saved, the next look still sees the move.
        guard !isMidAnswer else { return .deferred }
        entryCheckedAt = now
        morningSession.reset()
        eveningSession.reset()
        VoicePlayback.shared.stop()
        resetRoot(to: entryScreen)
        return .moved
    }

    /// The next moment the clock alone can change the entry screen.
    var nextEntryBoundary: Date {
        DayEngine(calendar: calendar).nextBoundary(after: now, rhythm: settings.rhythm)
    }
}
