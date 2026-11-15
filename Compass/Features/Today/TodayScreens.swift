import SwiftUI
import CompassCore

/// Today flow entry point. Owned by the Today flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum TodayScreens {
    /// C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C11b
    static let ids: [ScreenID] = Flow.today.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        TodayStub(id: id)
    }
}
