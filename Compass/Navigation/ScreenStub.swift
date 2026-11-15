import SwiftUI
import CompassCore

/// Placeholder for a screen that hasn't been built yet: shows its ID and board caption on the right
/// frame, with the flow's nav and dock so navigation works. Flow agents replace these.
struct ScreenStub: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    var body: some View {
        FlowScreen {
            NavBar(leading: leading, trailing: trailing, progress: id.flow == .onboarding ? onboardingProgress : nil)
                .region(.nav)

            SubjectLine(icon: subjectIcon, text: "\(id.flow.rawValue) · \(id.flow.title)")
                .region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(id.rawValue).compassFont(.display)
                Text(id.title).compassFont(.title).fixedSize(horizontal: false, vertical: true)
                Text(id.caption).compassFont(.body).foregroundStyle(.ink2).fixedSize(horizontal: false, vertical: true)
                Text("Stub · \(id.designRender)").compassFont(.micro).foregroundStyle(.ink3)
                if !CompassType.fontsLoaded {
                    Text("Inter Tight not loaded").compassFont(.micro).foregroundStyle(.destructive)
                }
            }
            .region(.focal)

            dock
        }
    }

    private var leading: NavItem? {
        switch id.flow {
        case .morning, .evening: .close { model.closeRitual() }
        case .onboarding where id == .a1: nil
        default: .back { model.back() }
        }
    }

    private var trailing: NavItem? { nil }

    private var onboardingProgress: Int? {
        switch id {
        case .a2, .a3, .a4, .a4k, .a4b, .a8: 1
        case .a5: 2
        case .a6: 3
        case .a7: 4
        default: nil
        }
    }

    private var subjectIcon: CompassIcon? {
        switch id.flow {
        case .morning: .sun
        case .evening: .moon
        case .history: .flag
        case .settings: .set
        case .system: .bell
        default: nil
        }
    }

    @ViewBuilder
    private var dock: some View {
        switch id.flow {
        case .morning:
            VoiceDock(micMode: id == .b1 ? .breathing : .rings, onKeyboard: next, onMic: next) {
                LinkButton("Skip") { model.closeRitual() }
            }
            .region(.dock)
        case .evening:
            ChoiceCircles(yes: "Done", no: "Not today", onYes: next, onNo: next)
                .region(.dock)
        default:
            ButtonDock(primary: id.next.map { "Next · \($0.rawValue)" } ?? "Start over", link: "Today", onPrimary: next) {
                model.reset(to: ScreenID.entry(for: .today, today: model.today))
            }
        }
    }

    private func next() {
        if let n = id.next { model.go(n) } else { model.goToEntry() }
    }
}
