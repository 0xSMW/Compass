import SwiftUI
import CompassCore

/// Morning flow entry point. Owned by the Morning flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum MorningScreens {
    /// B1 B2 B3 B4 B5 B6 B7 B8
    static let ids: [ScreenID] = Flow.morning.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
