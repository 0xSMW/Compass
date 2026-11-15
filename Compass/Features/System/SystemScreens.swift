import SwiftUI
import CompassCore

/// System flow entry point. I2 and I3 are Today with a notice in the notes row, so they render the
/// Today view; I1 and I4 replace the voice dock with "Type instead" on the 712 line; I5 and I6 draw the
/// lock screen and home screen as the reminders and widgets appear.
enum SystemScreens {
    /// I1 I2 I3 I4 I5 I6
    static let ids: [ScreenID] = Flow.system.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .i1: SystemMicrophoneOffView()
        case .i2, .i3: TodayView(id: id)
        case .i4: SystemStorageFullView()
        case .i5: SystemLockScreenView()
        case .i6: SystemWidgetsView()
        default: ScreenStub(id: id)
        }
    }
}

/// Lock and home screen backdrop on I5/I6 (#0E0E10).
extension Color {
    static let systemBackdrop = Color(hex: 0x0E0E10)
}

// MARK: - I1 · Microphone off

/// Center keeps its text; the dock becomes Type instead. Typing answers "Who will you be today?" and
/// continues to planning, like the spoken answer would.
struct SystemMicrophoneOffView: View {
    @Environment(AppModel.self) private var model
    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowScreen {
            NavBar(leading: NavItem(content: .icon(.x), label: "Not now", quiet: false) { model.closeRitual() })
                .region(.nav)

            if typing {
                if let goal = model.goal {
                    SubjectLine(text: goal.text).region(.subject)
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("Who will you be today?").compassFont(.title)
                    UnderlineField(prompt: "Patient. Ship one thing.", text: $text, style: .live, focused: $focused)
                        .submitLabel(.continue)
                        .onSubmit { save() }
                }
                .region(.focal)
                PrimaryButton("Continue") { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .region(.aboveKeyboard)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    TodayLineBoxText(text: model.goal?.text ?? "", style: .display)
                        .accessibilityAddTraits(.isHeader)
                    Text("Who will you be today?")
                        .compassFont(.heading)
                        .foregroundStyle(.ink2)
                        .padding(.top, Space.m)
                }
                .region(.focalTop)

                SystemRecordingNotice(block: .microphoneOff)
                    .region(.growsUp(bottom: 660))

                ButtonDock(primary: "Type instead", primaryIcon: .kb, link: "Turn on the microphone",
                           onPrimary: { startTyping() }, onLink: { model.turnOnMicrophone() })
            }
        }
        .onChange(of: model.conditions.microphone) { _, state in
            // Microphone back on: return to Center with the mic.
            if state == .granted, model.fixture == nil { model.replace(with: .b1) }
        }
    }

    private func startTyping() {
        typing = true
        DispatchQueue.main.async { focused = true }
    }

    private func save() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        var next: ScreenID = .b3
        if case .morning(let plan) = model.phase, case .nameYourOwn = plan.planning { next = .b4 }
        focused = false
        model.setIntention(answer)
        model.replace(with: next)
    }
}

// MARK: - I4 · Storage full

/// Recording can't start; typing takes the 712 line. Typing answers "What happened?" and saves the
/// evening entry as text.
struct SystemStorageFullView: View {
    @Environment(AppModel.self) private var model
    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let step = model.today?.step
        FlowScreen {
            NavBar(leading: .close { model.closeRitual() }).region(.nav)

            if let step {
                SubjectLine(icon: model.part(step.partID).map { CompassIcon($0.symbol) }, text: step.title).region(.subject)
            } else if let goal = model.goal {
                SubjectLine(text: goal.text).region(.subject)
            }

            if typing {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("What happened?").compassFont(.title)
                    UnderlineField(prompt: "", text: $text, style: .live, focused: $focused)
                }
                .region(.focal)
                PrimaryButton("Save") { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .region(.aboveKeyboard)
            } else {
                Text("What happened?")
                    .compassFont(.title)
                    .accessibilityAddTraits(.isHeader)
                    .region(.focal)

                SystemRecordingNotice(block: .storageFull)
                    .region(.growsUp(bottom: 660))

                ButtonDock(primary: "Type instead", primaryIcon: .kb, link: "Manage storage",
                           onPrimary: { startTyping() }, onLink: { model.openSystemSettings() })
            }
        }
    }

    private func startTyping() {
        typing = true
        DispatchQueue.main.async { focused = true }
    }

    private func save() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        focused = false
        let step = model.today?.step
        if let step, !step.isDone { model.setStepDone(true) }
        model.saveReflection(Reflection(outcome: .moved, transcript: answer, partID: step?.partID,
                                        createdAt: model.now, device: "This iPhone"))
        model.replace(with: .d5)
    }
}

// MARK: - I5 · Notifications

/// The lock screen at 07:00: the morning reminder shows the goal; last night's shows the step.
/// Same text the scheduler sends (`NotificationPlanner.body`).
struct SystemLockScreenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rhythm = model.settings.rhythm
        let yesterday = model.snapshot.day(model.todayKey.adding(days: -1, calendar: model.calendar))
        FlowScreen(background: .systemBackdrop) {
            VStack(spacing: 0) {
                Text(dateText).compassFont(.heading).foregroundStyle(.noticeInk)
                Text("\(rhythm.morning.hour):" + String(format: "%02d", rhythm.morning.minute))
                    .font(.custom(CompassType.Weight.semibold.interTight, fixedSize: 96))
                    .tracking(-0.04 * 96)
                    .frame(height: 96)
            }
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(.large)
            .accessibilityElement(children: .combine)
            .region(.focalTop)

            VStack(spacing: Space.xs) {
                if let morning = NotificationPlanner.body(for: .morning, goal: model.goal, day: model.today) {
                    SystemNotificationBanner(time: "now", message: morning)
                }
                if let evening = NotificationPlanner.body(for: .evening, goal: model.goal, day: yesterday) {
                    SystemNotificationBanner(time: "yesterday \(rhythm.evening.description)", message: evening)
                        .opacity(0.8)
                }
            }
            .region(.growsUp(bottom: 656))
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = model.calendar.timeZone
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: model.now)
    }
}

/// A notification as iOS draws it on the lock screen (system.html `.ntf`).
struct SystemNotificationBanner: View {
    var time: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            SystemAppIcon()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Compass").compassFont(.caption, weight: .semibold).foregroundStyle(.ink)
                    Spacer(minLength: Space.xs)
                    Text(time).compassFont(.caption).foregroundStyle(.ink2)
                }
                Text(message)
                    .compassFont(.caption)
                    .foregroundStyle(Color(hex: 0xE6E6E8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x2C2C30, opacity: 0.94), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The app icon mark: ground tile, hairline border, ink ring.
struct SystemAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ground)
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line2, lineWidth: 1)
            Circle().strokeBorder(Color.ink, lineWidth: 3).frame(width: 16, height: 16)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - I6 · Widgets

/// The home screen with the medium and small widgets, drawn with the widget's own views
/// (`TodayWidgetContent`). The circle completes today's step here too.
struct SystemWidgetsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let data = TodayWidgetData(snapshot: model.snapshot, day: model.todayKey)
        FlowScreen(background: .systemBackdrop) {
            VStack(spacing: Space.m) {
                widget(data, .medium)
                    .frame(height: 160)
                HStack(alignment: .top, spacing: Space.m) {
                    widget(data, .small)
                        .frame(width: 160, height: 160)
                    appGrid(columns: 2, count: 4, rowSpacing: 28)
                }
                appGrid(columns: 4, count: 8)
            }
            .dynamicTypeSize(.large)
            .region(.custom(top: 72, bottom: nil))
        }
    }

    private func widget(_ data: TodayWidgetData, _ layout: TodayWidgetLayout) -> some View {
        TodayWidgetContent(data: data, layout: layout) { done in
            Button {
                model.setStepDone(!done)
                if !done {
                    Feedback.complete()
                    Feedback.announce("Done, undo available")
                }
            } label: {
                TodayWidgetCircle(done: done)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Done. Tap to reopen" : "Mark step done")
        }
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func appGrid(columns: Int, count: Int, rowSpacing: CGFloat = Space.m) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m), count: columns), spacing: rowSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.raised).frame(height: 64)
            }
        }
        .accessibilityHidden(true)
    }
}
