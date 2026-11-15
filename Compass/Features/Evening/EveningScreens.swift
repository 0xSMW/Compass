import SwiftUI
import CompassCore

/// Evening flow entry point. Owned by the Evening flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum EveningScreens {
    /// D1 D1L D2 D2b D3 D3L D4 D5 D5L D6 D6b D7 D8
    static let ids: [ScreenID] = Flow.evening.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
