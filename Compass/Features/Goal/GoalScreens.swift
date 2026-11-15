import SwiftUI
import CompassCore

/// Goal changes flow entry point. Owned by the Goal changes flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum GoalScreens {
    /// G1 G2 G3
    static let ids: [ScreenID] = Flow.goal.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
