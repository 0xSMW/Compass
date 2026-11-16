import SwiftUI
import CompassCore

/// Tells the user, once per launch, that the saved data couldn't be read (item 19). The file was copied
/// aside before anything else happened (`JSONFileStore.loadRecovering`), so nothing is lost.
struct StoreProblemAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let problem = model.storeProblem
        content.alert(
            Self.title(problem),
            isPresented: Binding(get: { model.storeProblem != nil }, set: { shown in
                // A newer-schema store keeps blocking saves; only the message goes away.
                if !shown { model.storeProblem = nil }
            }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(Self.message(problem)) }
        )
    }

    static func title(_ problem: StoreProblem?) -> String {
        switch problem?.kind {
        case .newerSchema?: return "Update Compass"
        default: return "Compass couldn’t read its data"
        }
    }

    static func message(_ problem: StoreProblem?) -> String {
        switch problem?.kind {
        case .newerSchema?:
            return "Your data was saved by a newer version of Compass. Update Compass to open it. Nothing has been changed or deleted."
        default:
            return "A copy of the file was kept on this iPhone. If you use iCloud, your history comes back as it syncs."
        }
    }
}

extension View {
    /// Shows `StoreProblemAlert` when the store couldn't be read at launch.
    func storeProblemAlert() -> some View { modifier(StoreProblemAlert()) }
}
