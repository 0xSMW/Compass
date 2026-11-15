import SwiftUI
import CompassCore

/// Onboarding flow entry point. Owned by the Onboarding flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum OnboardingScreens {
    /// A1 A2 A3 A4 A4k A4b A5 A6 A7 R1 R2 R3 A8
    static let ids: [ScreenID] = Flow.onboarding.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
