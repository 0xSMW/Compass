import SwiftUI
import CompassCore

/// Lapse and return flow entry point (F1–F3). ScreenRegistry calls `view(for:)`.
///
/// DayEngine decides when these show: 1–2 quiet days → the morning plan uses a smaller step (F1);
/// 3–29 → F2; 30+ → F3 (`ScreenID.entry(for:)`). F2 "Plan one small step" and F3 "Keep it" lead into
/// F1; F3 "Revise it" opens the goal (G1); "Set a new goal" runs onboarding again.
enum ReturnScreens {
    /// F1 F2 F3
    static let ids: [ScreenID] = Flow.lapse.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .f1: ReturnSmallerStepView()
        case .f2: ReturnWelcomeView()
        case .f3: ReturnGoalCheckView()
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}
