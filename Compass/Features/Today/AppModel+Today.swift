import Foundation
import CompassCore

/// Today actions (C6 options, planning from the empty card). Persist through `updateToday`, which also
/// reloads the widget timeline and, through the system services, re-plans the 21:00 reminder text.
extension AppModel {
    /// C6 · Change step (typed).
    func todayRenameStep(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateToday { $0.step?.title = trimmed }
    }

    /// C6 · Counts toward: <part>.
    func todayMoveStep(to partID: UUID?) {
        updateToday { $0.step?.partID = partID }
    }

    /// C1/C2 · + opens planning (voice or typing): name your own step in the first week or with cloud
    /// help off (B4), otherwise the suggestion for the quietest part (B3).
    var todayPlanningScreen: ScreenID {
        guard let goal, goal.status == .active else { return .a2 }
        let engine = DayEngine(calendar: calendar)
        let firstWeek = engine.goalDayNumber(goal: goal, today: todayKey) <= engine.firstWeekLength
        return firstWeek || !cloudHelpOn ? .b4 : .b3
    }
}
