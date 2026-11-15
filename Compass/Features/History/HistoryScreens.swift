import SwiftUI
import CompassCore

/// History flow entry point. Owned by the History flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum HistoryScreens {
    /// E1 E2 E3 E4 E5 E6
    static let ids: [ScreenID] = Flow.history.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
