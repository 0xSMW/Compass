import SwiftUI
import CompassCore

/// Settings flow entry point. Owned by the Settings flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum SettingsScreens {
    /// H1 H2
    static let ids: [ScreenID] = Flow.settings.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
