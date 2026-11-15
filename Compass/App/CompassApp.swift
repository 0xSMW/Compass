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
                .environment(model)
                .preferredColorScheme(.dark)
        }
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
