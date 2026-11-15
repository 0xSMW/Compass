import SwiftUI
import UIKit
import CompassCore

// MARK: - Actions

extension AppModel {
    /// Leave a return screen for Today. A morning with no trace yet is marked skipped, so the
    /// return screen isn't shown again today (DayEngine counts the day as active).
    func returnLeaveForToday() {
        if !(today?.hasActivity ?? false) { skipMorning() }
        reset(to: ScreenID.entry(for: .today, today: today))
    }

    /// F1: the smaller idea for the quietest part (DayEngine), from cloud help when it's on.
    /// nil when cloud help is off or unreachable: the user names their own step instead.
    func returnSmallerIdea() async -> StepIdea? {
        guard let goal else { return nil }
        let engine = DayEngine(calendar: calendar)
        let part = engine.quietestPart(goal: goal, snapshot: snapshot, endingBefore: todayKey)
        let recent = Array(snapshot.sortedDays.filter { $0.key < todayKey }.suffix(14))
        return try? await cloud.suggestStep(goal: goal, part: part, size: .smaller, recent: recent)
    }

    /// F1 "Use this": today's step, marked smaller and suggested.
    func returnUse(_ idea: StepIdea) {
        setStep(title: idea.title, partID: idea.partID, size: .smaller, source: .suggested)
        reset(to: ScreenID.entry(for: .today, today: today))
    }
}

// MARK: - F1 · After 2 quiet days

/// The normal plan frame (B3) with a smaller step: "Smaller than usual. It still counts."
/// Reached from Center after 1–2 quiet days, and from F2/F3 on the way back.
struct ReturnSmallerStepView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced

    @State private var idea: StepIdea?
    @State private var loaded = false

    var body: some View {
        let intention = model.today?.intention
        let part = model.part(idea?.partID)
        FlowScreen {
            NavBar(leading: NavItem(content: .icon(.x), label: "Not now", quiet: false, action: { model.returnLeaveForToday() }))
                .region(.nav)

            if let intention {
                HStack(alignment: .top, spacing: Space.xs) {
                    Text("“\(intention.text)”")
                        .compassFont(.body)
                        .foregroundStyle(.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    IconButton(.redo, label: "Say your intention again", bare: true) { model.replace(with: .b1) }
                        .padding(.top, -10)
                        .padding(.trailing, -10)
                }
                .region(.subject)
            }

            if idea == nil, model.fixture == nil {
                StepIdeaLoading(title: "Finding a smaller step…")
                    .region(.focal)
            } else if let idea {
                VStack(alignment: .leading, spacing: 0) {
                    Text(idea.title)
                        .compassFont(.title)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.xs) {
                        if let part { Icon(CompassIcon(part.symbol), size: IconSize.s) }
                        Text("Smaller than usual. It still counts.")
                            .compassFont(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.ink3)
                    .padding(.top, Space.s)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((part.map { "\($0.title). " } ?? "") + "Smaller than usual. It still counts.")
                }
                .region(.focal)
                .transition(.opacity)
            }

            HStack(spacing: Space.s) {
                PrimaryButton("Use this", icon: .ok) {
                    if let idea { model.returnUse(idea) }
                }
                .opacity(idea == nil ? 0.4 : 1)
                .disabled(idea == nil)
                CircleButton(.mic, label: "Say my own step", style: .ink) { model.replace(with: .b4) }
            }
            .region(.buttonDock)

            LinkButton("No step today") { model.returnLeaveForToday() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: idea)
        .task {
            guard !loaded else { return }
            loaded = true
            if let found = await model.returnSmallerIdea() {
                idea = found
            } else {
                // Cloud help is off: no ideas, so the user names a step (B4).
                model.replace(with: .b4)
            }
        }
    }
}

// MARK: - F2 · After 3–29 quiet days

/// What you've done, your own reason, one way back. Totals only; nothing to lose.
struct ReturnWelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    @State private var showsWhy = false

    var body: some View {
        let summary = ReturnSummary(snapshot: model.snapshot, today: model.todayKey, calendar: model.calendar)
        FlowScreen {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(summary.steps)")
                        .font(.custom(CompassType.display.fontName(.semibold), fixedSize: 96))
                        .tracking(-0.05 * 96)
                        .frame(height: 96)
                    Text(summary.stepsCaption)
                        .compassFont(.heading)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(summary.steps) \(summary.stepsCaption)")

                if let last = summary.lastLine {
                    Text(last)
                        .compassFont(.body)
                        .foregroundStyle(.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.m)
                }

                if let why = summary.why {
                    // B7's recording plays (`<note id>.m4a`); the words show with it, and stand in
                    // for it when there is no recording on this phone.
                    let audio = MemoAudio.fileName(for: why).flatMap { VoiceStorage.shared.exists($0) ? $0 : nil }
                    Chip(title: "Hear why you started", icon: showsWhy ? .x : .play,
                         accessibilityLabel: showsWhy ? "Hide why you started" : "Hear why you started",
                         tint: .ink) {
                        withAnimation(Motion.animation(Motion.turnTaking, reduced: reduced)) { showsWhy.toggle() }
                        if let audio {
                            if showsWhy {
                                if !VoicePlayback.shared.isPlaying(audio) { VoicePlayback.shared.toggle(audio) }
                            } else {
                                VoicePlayback.shared.stop()
                            }
                        } else if showsWhy {
                            UIAccessibility.post(notification: .announcement, argument: why.text)
                        }
                    }
                    .padding(.top, Space.m)
                    if showsWhy {
                        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                            Text("“\(why.text)”")
                                .compassFont(.body)
                                .foregroundStyle(.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let d = why.duration {
                                Text(Player.format(d)).compassFont(.micro).foregroundStyle(.ink3)
                            }
                        }
                        .padding(.top, Space.s)
                        .transition(.opacity)
                    }
                }
            }
            .region(.focalTop)

            ButtonDock(primary: "Plan one small step", link: "Not today", onPrimary: {
                model.replace(with: .f1)
            }, onLink: {
                model.returnLeaveForToday()
            })
        }
        .onDisappear { VoicePlayback.shared.stop() }
    }
}

// MARK: - F3 · After 30+ quiet days

/// Keep, revise or replace; history stays either way.
struct ReturnGoalCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = ReturnSummary(snapshot: model.snapshot, today: model.todayKey, calendar: model.calendar)
        FlowScreen {
            VStack(alignment: .leading, spacing: 0) {
                Text("Still where you’re going?")
                    .compassFont(.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let goal = model.goal {
                    Text(goal.text)
                        .compassFont(.heading)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s)
                }
                Text(summary.checkLine)
                    .compassFont(.body)
                    .foregroundStyle(.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.s)
            }
            .region(.focalTop)

            SecondaryButton("Revise it") { model.go(.g1) }
                .region(.buttonDockHigh)

            ButtonDock(primary: "Keep it", link: "Set a new goal", onPrimary: {
                // Same goal: back in with a smaller step.
                model.replace(with: .f1)
            }, onLink: {
                // A new goal through onboarding's goal steps; the old one and its history move to past
                // goals, and the rhythm and privacy choices stay.
                model.startNewGoal()
            })
        }
    }
}
