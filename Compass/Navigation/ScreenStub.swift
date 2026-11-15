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

/// Today stub: the real TodayScaffold with fixture data, tagged with the screen ID, so the layout
/// can be compared against the boards before the Today flow is built.
struct TodayStub: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    var body: some View {
        let today = model.today
        let step = today?.step
        let part = model.part(step?.partID)
        TodayScaffold(
            onHistory: { model.go(.e1) },
            onSettings: { model.go(.h1) },
            forceScrolledToEnd: id == .c11b
        ) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(model.goal?.text ?? "").compassFont(.title)
                if let intention = today?.intention {
                    Text("“\(intention.text)”").compassFont(.body).foregroundStyle(.ink2)
                }
                Text("\(id.label) · stub").compassFont(.micro).foregroundStyle(.ink3)
            }
        } notes: {
            if let note = today?.notes.last {
                NoteRow(text: note.text, duration: note.duration)
            }
        } card: {
            if let step {
                StepCard(
                    title: step.title,
                    partTitle: part?.title,
                    partIcon: part.map { CompassIcon($0.symbol) },
                    state: step.isDone ? .justDone : .open,
                    onToggle: { model.setStepDone($0) },
                    onUndo: { model.setStepDone(false) }
                )
            } else {
                StepCard(
                    title: "",
                    state: today?.intention == nil ? .empty(title: "No step yet", label: "Add one step for today")
                                                   : .empty(title: "No step today", label: "You can still add one"),
                    onPlan: { model.go(.b4) }
                )
            }
        } dock: {
            TodayDock(onKeyboard: {}, onNote: {})
        }
    }
}
