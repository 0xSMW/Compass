import SwiftUI
import CompassCore

/// Morning flow entry point (B1–B8). Screens replace each other in place (turn-taking); the
/// transient state between them lives in `MorningSession` and `VoiceCapture`.
enum MorningScreens {
    /// B1 B2 B3 B4 B5 B6 B7 B8
    static let ids: [ScreenID] = Flow.morning.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .b1, .b8: MorningCenterView()
        case .b2: MorningListeningView()
        case .b3, .b6: MorningPlanView(id: id)
        case .b4: MorningNameStepView()
        case .b5: MorningTypingView()
        case .b7: MorningWhyView()
        default: ScreenStub(id: id)
        }
    }
}
