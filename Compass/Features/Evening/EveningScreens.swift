import SwiftUI
import CompassCore

/// Evening flow entry point (D1–D8). One frame for the whole evening: the subject sits at 128, the
/// question / prompt / summary take turns at 224, the controls hold the 712 line. Transient state
/// between screens lives in `EveningSession` and `VoiceCapture`.
enum EveningScreens {
    /// D1 D1L D2 D2b D3 D3L D4 D5 D5L D6 D6b D7 D8
    static let ids: [ScreenID] = Flow.evening.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .d1, .d1L, .d2, .d7: EveningQuestionView()
        case .d2b: EveningDoneEarlierView()
        case .d3, .d3L, .d4: EveningReflectView(id: id)
        case .d5, .d5L, .d6, .d6b, .d8: EveningSavedView(id: id)
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}
