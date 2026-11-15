import SwiftUI
import CompassCore

/// Lapse and return flow entry point. Owned by the Lapse and return flow: replace the stub with real views, one per
/// ScreenID (keep this signature; ScreenRegistry calls it). Fixture data for each ID comes from
/// `AppModel` (`model.snapshot`, `model.fixture`, `model.conditions`), seeded by `Fixtures.fixture(for:)`.
enum ReturnScreens {
    /// F1 F2 F3
    static let ids: [ScreenID] = Flow.lapse.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        ScreenStub(id: id)
    }
}
