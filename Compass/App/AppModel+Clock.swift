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
///
/// Two other events judge the screen the same way: a merge from another device that changes today's
/// phase (the iPad finished the morning, so the iPhone leaves B1), and a tapped reminder. Both wait
/// for an answer in progress too (`pendingEntryMove`), and happen once it ends.
extension AppModel {
    enum ClockRefresh: Equatable {
        /// Same day, same part of the day (or a screen the clock doesn't own).
        case unchanged
        /// The root screen was replaced by the new entry screen.
        case moved
        /// The clock moved, but an answer is being said or typed; look again shortly.
        case deferred
    }

    /// A move that waits for the answer in progress to end.
    enum PendingEntryMove: Equatable {
        /// A merge changed today's phase: replace the day-flow root, keep History/Settings on top.
        case root
        /// A reminder was tapped: open the screen for the moment (the whole stack, as before).
        case reminder
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

    private var rootIsDayFlow: Bool {
        guard let root = path.first else { return false }
        return Self.dayFlows.contains(root.flow)
    }

    /// Judge the screen against the clock. Both moments are judged on today's data, so saving an
    /// intention or a step (which changes the phase by itself) never counts as the clock moving.
    /// A move that waited for an answer (`pendingEntryMove`) happens here once the answer has ended.
    @discardableResult
    func refreshEntryForClock() -> ClockRefresh {
        if let pending = pendingEntryMove {
            guard !isMidAnswer else { return .deferred }
            performEntryMove(pending)
            return .moved
        }
        let now = self.now
        guard let then = entryCheckedAt else {
            entryCheckedAt = now
            return .unchanged
        }
        guard DayEngine(calendar: calendar).clockMoved(from: then, to: now, snapshot: snapshot), rootIsDayFlow else {
            entryCheckedAt = now
            return .unchanged
        }
        // Keep `then`: once the answer is saved, the next look still sees the move.
        guard !isMidAnswer else { return .deferred }
        performEntryMove(.root)
        return .moved
    }

    /// F2: a merge from another device replaced the snapshot. When it changed today's phase (the morning
    /// was handled, the evening answered, the step done), the screen is judged again like the clock does.
    @discardableResult
    func refreshEntryAfterMerge(phaseBefore: DayPhase) -> ClockRefresh {
        guard !DayEngine.sameStage(phaseBefore, phase), rootIsDayFlow else { return .unchanged }
        guard !isMidAnswer else {
            if pendingEntryMove == nil { pendingEntryMove = .root }
            return .deferred
        }
        performEntryMove(.root)
        return .moved
    }

    /// F3: a reminder was tapped. Opens the screen for the moment, but never under an answer being
    /// said or typed: then it waits until the answer ends.
    @discardableResult
    func openFromReminder() -> ClockRefresh {
        guard !isMidAnswer else {
            pendingEntryMove = .reminder
            return .deferred
        }
        performEntryMove(.reminder)
        return .moved
    }

    private func performEntryMove(_ move: PendingEntryMove) {
        pendingEntryMove = nil
        entryCheckedAt = now
        // A merge's move waited while the user left the day's screens (Goal, onboarding): nothing to move.
        if move == .root, !rootIsDayFlow { return }
        morningSession.reset()
        eveningSession.reset()
        VoicePlayback.shared.stop()
        switch move {
        case .root: resetRoot(to: entryScreen)
        case .reminder: goToEntry()
        }
    }

    /// The next moment the clock alone can change the entry screen.
    var nextEntryBoundary: Date {
        DayEngine(calendar: calendar).nextBoundary(after: now, rhythm: settings.rhythm)
    }
}
