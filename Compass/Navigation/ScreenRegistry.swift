import SwiftUI
import CompassCore

/// ScreenID → view. Shared file: every one of the 66 IDs already routes to its flow's entry file.
/// Flow folders own `Features/<Flow>/<Flow>Screens.swift` and switch on the ID there.
enum ScreenRegistry {
    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id.flow {
        case .onboarding: OnboardingScreens.view(for: id)
        case .morning: MorningScreens.view(for: id)
        case .today: TodayScreens.view(for: id)
        case .evening: EveningScreens.view(for: id)
        case .history: HistoryScreens.view(for: id)
        case .lapse: ReturnScreens.view(for: id)
        case .goal: GoalScreens.view(for: id)
        case .settings: SettingsScreens.view(for: id)
        case .system: SystemScreens.view(for: id)
        }
    }
}
