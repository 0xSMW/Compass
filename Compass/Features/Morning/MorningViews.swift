import SwiftUI
import CompassCore

private extension AppModel {
    var morningClose: NavItem { .ritualClose("Not now") { self.closeMorning() } }
}

// MARK: - B1 · Center, B8 · Largest text

/// The goal is the focal text at 128; "Who will you be today?" under it; breathing rings on 712.
struct MorningCenterView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { .shared }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            VStack(alignment: .leading, spacing: Space.m) {
                Text(model.goal?.text ?? "")
                    .compassFont(.display)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MorningSession.Purpose.intention.question)
                    .compassFont(.heading)
                    .foregroundStyle(.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .region(.focalTop)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.intention) }
            } else {
                RitualVoiceDock(
                    micMode: .breathing,
                    micLabel: "Speak your intention",
                    onKeyboard: { model.openMorningTyping(.intention) },
                    onMic: { model.startMorningListening(.intention) }
                ) {
                    DockSkip { Task { await model.continueToPlanning() } }
                }
                .region(.dock)
            }
        }
    }
}

// MARK: - B2 · Speaking

/// The goal shrinks into the subject; the question greys at 224 and the words land under it.
/// Also listens for a spoken step (subject: the intention) and for "why" (B7).
struct MorningListeningView: View {
    @Environment(AppModel.self) private var model
    private var capture: VoiceCapture { .shared }
    private var session: MorningSession { .shared }

    private var purpose: MorningSession.Purpose { session.purpose ?? .intention }
    /// Fixture screenshot: the board's words, nothing recording.
    private var showsFixture: Bool { model.fixture != nil && !capture.isBusy }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            RitualSubject(text: subject).region(.subject)

            ListeningFocal(
                question: purpose.question,
                settled: showsFixture ? (model.fixture?.transcript?.settled ?? "") : capture.settled,
                pending: showsFixture ? (model.fixture?.transcript?.pending ?? "") : capture.pending
            )
            .region(.focal)

            ListeningWave(levels: showsFixture ? FakeAudioRecorder.designLevels : capture.levels, isStatic: showsFixture)
                .region(.wave)

            RitualVoiceDock(
                micMode: .listening,
                micLabel: "Stop and save",
                onKeyboard: { model.openMorningTyping(purpose) },
                onMic: { Task { await model.finishMorningListening() } }
            )
            .region(.dock)
        }
        .onAppear {
            capture.onSilence = { Task { await model.finishMorningListening() } }
        }
    }

    private var subject: String {
        switch purpose {
        case .intention, .why: model.goal?.text ?? ""
        case .step: model.morningPlanningSubject
        }
    }
}

// MARK: - B3 · Plan, with a suggestion · B6 · Opened after noon

/// The suggested step at 224 with its part and a meta line; "Use this" and "Say my own step" on 712,
/// "No step today" under it.
struct MorningPlanView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID
    private var session: MorningSession { .shared }

    private var idea: StepIdea? {
        session.idea ?? (model.fixture != nil ? Fixtures.stepIdea(for: id) : nil)
    }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            subject.region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                if let idea {
                    Text(idea.title)
                        .compassFont(.title)
                        .fixedSize(horizontal: false, vertical: true)
                    let part = model.part(idea.partID)
                    HStack(alignment: .top, spacing: Space.xs) {
                        if let part { Icon(CompassIcon(part.symbol), size: IconSize.s) }
                        Text(MorningRules.planMeta(partTitle: part?.title, hint: idea.hint, stepsThisWeek: model.ritualStepsThisWeek(idea.partID)))
                            .compassFont(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.ink3)
                    .accessibilityElement(children: .combine)
                }
            }
            .region(.focal)

            if let problem = session.micProblem {
                Notice(icon: problem == .storageFull ? .disk : .micoff,
                       text: problem == .storageFull ? "Your iPhone is full, so audio can’t be saved." : "The microphone is off for Compass.")
                    .region(.growsUp(bottom: 660))
            }

            HStack(spacing: Space.s) {
                PrimaryButton("Use this", icon: .ok) {
                    if let idea { model.useSuggestedStep(idea) }
                }
                .disabled(idea == nil)
                CircleButton(.mic, label: "Say my own step", style: .ink) {
                    if session.micProblem != nil || model.recorder.permission == .denied {
                        model.openMorningTyping(.step)
                    } else {
                        model.startMorningListening(.step)
                    }
                }
            }
            .region(.buttonDock)

            LinkButton("No step today") { model.noStepToday() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
        .onAppear { if idea == nil { model.loadMorningIdeaIfNeeded() } }
    }

    @ViewBuilder
    private var subject: some View {
        if model.today?.intention != nil {
            RitualSubject(text: model.morningPlanningSubject, redoLabel: "Say your intention again") {
                model.startMorningListening(.intention)
            }
        } else {
            RitualSubject(text: model.goal?.text ?? "")
        }
    }
}

// MARK: - B4 · First week

/// No history yet, so you name the step: "What's one step today?" with the voice dock.
struct MorningNameStepView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { .shared }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            if model.today?.intention != nil {
                RitualSubject(text: model.morningPlanningSubject, redoLabel: "Say your intention again") {
                    model.startMorningListening(.intention)
                }
                .region(.subject)
            } else {
                RitualSubject(text: model.goal?.text ?? "").region(.subject)
            }

            Text(MorningSession.Purpose.step.question)
                .compassFont(.title)
                .fixedSize(horizontal: false, vertical: true)
                .region(.focal)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.step) }
            } else {
                RitualVoiceDock(
                    micMode: .rings,
                    micLabel: "Say a step",
                    onKeyboard: { model.openMorningTyping(.step) },
                    onMic: { model.startMorningListening(.step) }
                ) {
                    DockSkip(accessibilityLabel: "No step today") { model.noStepToday() }
                }
                .region(.dock)
            }
        }
    }
}

// MARK: - B5 · Typing a step (and typed intention / why)

/// Keyboard up: the field stays at 224, typed text goes where spoken words would appear, and the
/// action sits on the keyboard at 436. For a step, the part chip sits under the field.
struct MorningTypingView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { .shared }

    @State private var text = ""
    @State private var partID: UUID?
    @FocusState private var focused: Bool

    private var purpose: MorningSession.Purpose { session.purpose ?? .step }
    private var isFixture: Bool { model.fixture != nil }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            RitualSubject(text: purpose == .step ? model.morningPlanningSubject : (model.goal?.text ?? ""))
                .region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                UnderlineField(prompt: purpose.question, text: $text, style: .title, focused: $focused, showsFocus: isFixture)
                    .accessibilityLabel(purpose == .step ? "Today’s step" : purpose.question)
                if purpose == .step, let goal = model.goal {
                    PartPickerChip(parts: goal.activeParts, selected: model.part(partID)) { part in
                        partID = part.id
                        session.draftPartID = part.id
                    }
                }
            }
            .region(.focal)

            AboveKeyboardAction(
                title: purpose == .step ? "Add step" : "Save",
                enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                drawsKeyboard: isFixture,
                action: save
            )
        }
        .onAppear {
            if isFixture && session.purpose == nil {
                text = Fixtures.workStepTitle
                partID = model.morningDefaultPartID
            } else {
                text = session.draft
                partID = session.draftPartID ?? model.morningDefaultPartID
                focused = true
            }
        }
    }

    private func save() {
        focused = false
        switch purpose {
        case .step: model.addTypedStep(text, partID: partID)
        case .intention: model.saveTypedIntention(text)
        case .why:
            let tidy = MorningRules.why(from: text)
            guard !tidy.isEmpty else { return }
            model.saveWhy(tidy, recording: nil)
            model.replace(with: .b1)
        }
    }
}

// MARK: - B7 · Day 3: why it matters

struct MorningWhyView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { .shared }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            RitualSubject(text: model.goal?.text ?? "").region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(MorningSession.Purpose.why.question)
                    .compassFont(.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You’ll hear your answer on hard days.")
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .region(.focal)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.why) }
            } else {
                RitualVoiceDock(
                    micMode: .rings,
                    micLabel: "Say why",
                    onKeyboard: { model.openMorningTyping(.why) },
                    onMic: { model.startMorningListening(.why) }
                ) {
                    DockSkip { model.skipWhy() }
                }
                .region(.dock)
            }
        }
    }
}
