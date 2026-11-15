import SwiftUI
import CompassCore

/// System flow entry point. Owned by the System flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum SystemScreens {
    /// I1 I2 I3 I4 I5 I6
    static let ids: [ScreenID] = Flow.system.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
