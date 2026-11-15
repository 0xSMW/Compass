import SwiftUI
import CompassCore

/// Onboarding flow entry point (A1–A8, A4b, A4k, R1–R3). ScreenRegistry calls `view(for:)`.
///
/// Live path: A1 Begin → A2 (say or type) → A3 listening → A4 review (A4k typing, A4b one question
/// for a vague goal) → A5 parts → A6 rhythm + notification permission → A7 privacy → Start saves the
/// goal and lands by the clock. A1 Restore → R1 → R2 (or R3 when there's nothing to restore).
/// What the user has said so far lives in `model.onboardingDraft`.
enum OnboardingScreens {
    /// A1 A2 A3 A4 A4k A4b A5 A6 A7 R1 R2 R3 A8
    static let ids: [ScreenID] = Flow.onboarding.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .a1: OnboardingWelcomeView()
        case .a2, .a8: OnboardingGoalQuestionView(id: id)
        case .a3: OnboardingListeningView(id: id)
        case .a4, .a4k, .a4b: OnboardingReviewView(id: id)
        case .a5: OnboardingPartsView()
        case .a6: OnboardingRhythmView()
        case .a7: OnboardingPrivacyView()
        case .r1: RestoreProgressView(id: id)
        case .r2: RestoreDoneView()
        case .r3: RestoreNothingView()
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}
