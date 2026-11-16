import Foundation
import CompassCore

/// Goal changes. Every change keeps history: parts are archived, never deleted, and an ended goal
/// keeps its days (they stay tagged with its id). All go through `mutate`, so they save, sync and
/// reload the widget.
extension AppModel {
    func updateGoalText(_ text: String) {
        mutate { $0.goal?.text = text }
    }

    func renameGoalPart(_ id: UUID, to title: String) {
        mutate { s in
            guard let i = s.goal?.parts.firstIndex(where: { $0.id == id }) else { return }
            s.goal?.parts[i].title = title
        }
    }

    /// Removing a part archives its symbol; its past steps stay visible in History.
    func archiveGoalPart(_ id: UUID) {
        mutate { s in
            guard let i = s.goal?.parts.firstIndex(where: { $0.id == id }) else { return }
            s.goal?.parts[i].isArchived = true
        }
    }

    func addGoalPart(title: String) {
        mutate { s in
            guard var g = s.goal else { return }
            let used = Set(g.activeParts.map(\.symbol))
            let symbol = PartSymbol.allCases.first { !used.contains($0) } ?? .flag
            g.parts.append(GoalPart(title: title, symbol: symbol))
            s.goal = g
        }
    }

    /// G2: the end marker fills. The goal stays current until the next one is set, then moves to past goals.
    func markGoalAchieved() {
        let endedAt = now
        mutate { s in
            guard var g = s.goal else { return }
            g.status = .achieved
            g.endedAt = endedAt
            s.goal = g
            // Days already written keep pointing at this goal so its line survives the next goal.
            for i in s.days.indices where s.days[i].goalID == nil {
                s.days[i].goalID = g.id
            }
        }
    }
}
