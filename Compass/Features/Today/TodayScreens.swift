import SwiftUI
import CompassCore

/// Today flow entry point. Every C state is the same `TodayView`: the data decides C1/C2/C3/C4, and
/// local interaction state draws C4–C6 and C10 (seeded from the ID for screenshots). C7–C9 and
/// C11/C11b are the same view with other content and text sizes.
enum TodayScreens {
    /// C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C11b
    static let ids: [ScreenID] = Flow.today.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        TodayView(id: id)
    }
}
