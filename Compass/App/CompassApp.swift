import SwiftUI
import UIKit
import CompassCore

@main
struct CompassApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .systemServices()
                .storeProblemAlert()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .backgroundTask(.appRefresh(ReminderRefresh.taskID)) {
            await ReminderRefresh.run()
        }
    }
}

/// `-tapthrough` only: a small control on the left edge (clear of the status bar and the nav row) the UI
/// test taps to move the clock to 21:05, so the evening comes in the way the boundary timer brings it on
/// a phone. Its value counts the taps, so a failing test can tell a missed tap from a screen that stayed.
private struct TapThroughClockControl: View {
    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            model.advanceTapThroughClock(hour: 21, minute: 5)
        } label: {
            Color.white.opacity(0.05).frame(width: 24, height: 24)
        }
        .accessibilityLabel("Move the clock to the evening")
        .accessibilityValue("\(taps)")
        .accessibilityIdentifier("tapthrough-evening")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Renders the current ScreenID. Turn-taking cross-fades in place (200 ms; cut with Reduce Motion).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reduced = reduceMotion || model.launch.uiTest
        ZStack {
            Color.ground.ignoresSafeArea()
            ScreenRegistry.view(for: model.current)
                .id(model.current)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-\(model.current.rawValue)")
            if model.launch.tapThrough { TapThroughClockControl() }
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: model.current)
        .environment(\.motionReduced, reduced)
        .transformEnvironment(\.dynamicTypeSize) { size in
            if model.launch.forceAX5 { size = .accessibility5 }
        }
        .onAppear {
            if model.launch.uiTest { UIView.setAnimationsEnabled(false) }
        }
    }
}
