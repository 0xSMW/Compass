import Foundation
import CompassCore

/// Goal changes. Every change keeps history: parts are archived, never deleted, and an ended goal
/// keeps its days (they stay tagged with its id).
extension AppModel {
    func updateGoalText(_ text: String) {
        guard var g = snapshot.goal else { return }
        g.text = text
        snapshot.goal = g
        saveAndSync()
    }

    func renameGoalPart(_ id: UUID, to title: String) {
        guard var g = snapshot.goal, let i = g.parts.firstIndex(where: { $0.id == id }) else { return }
        g.parts[i].title = title
        snapshot.goal = g
        saveAndSync()
    }

    /// Removing a part archives its symbol; its past steps stay visible in History.
    func archiveGoalPart(_ id: UUID) {
        guard var g = snapshot.goal, let i = g.parts.firstIndex(where: { $0.id == id }) else { return }
        g.parts[i].isArchived = true
        snapshot.goal = g
        saveAndSync()
    }

    func addGoalPart(title: String) {
        guard var g = snapshot.goal else { return }
        let used = Set(g.activeParts.map(\.symbol))
        let symbol = PartSymbol.allCases.first { !used.contains($0) } ?? .flag
        g.parts.append(GoalPart(title: title, symbol: symbol))
        snapshot.goal = g
        saveAndSync()
    }

    /// G2: the end marker fills. The goal stays current until the next one is set, then moves to past goals.
    func markGoalAchieved() {
        guard var g = snapshot.goal else { return }
        g.status = .achieved
        g.endedAt = now
        snapshot.goal = g
        // Days already written keep pointing at this goal so its line survives the next goal.
        for i in snapshot.days.indices where snapshot.days[i].goalID == nil {
            snapshot.days[i].goalID = g.id
        }
        saveAndSync()
    }
}
