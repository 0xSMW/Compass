import SwiftUI
import CompassCore

private extension AppModel {
    var morningClose: NavItem { .close("Not now") { self.closeMorning() } }
}

// MARK: - B1 · Center, B8 · Largest text

/// The goal is the focal text at 128; "Who will you be today?" under it; breathing rings on 712.
struct MorningCenterView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { model.morningSession }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            VStack(alignment: .leading, spacing: Space.m) {
                CompassText(model.goal?.text ?? "", style: .display)
                    .accessibilityAddTraits(.isHeader)
                CompassText(MorningSession.Purpose.intention.question, style: .heading, color: .ink2)
            }
            .region(.focalTop)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.intention) }
            } else {
                VoiceDock(
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
        .onAppear {
            // Settings › Start with: Typing. The same question, typed (Skip stays in the nav).
            if model.prefersTyping, session.micProblem == nil { model.openMorningTyping(.intention) }
        }
    }
}

// MARK: - B2 · Speaking

/// The goal shrinks into the subject; the question greys at 224 and the words land under it.
/// Also listens for a spoken step (subject: the intention) and for "why" (B7).
struct MorningListeningView: View {
    @Environment(AppModel.self) private var model
    private var capture: VoiceCapture { model.voice }
    private var session: MorningSession { model.morningSession }

    private var purpose: MorningSession.Purpose { session.purpose ?? .intention }
    /// Fixture screenshot: the board's words, nothing recording.
    private var showsFixture: Bool { model.fixture != nil && !capture.isBusy }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            SubjectLine(text: subject).region(.subject)

            ListeningFocal(
                question: purpose.question,
                settled: showsFixture ? (model.fixture?.transcript?.settled ?? "") : capture.settled,
                pending: showsFixture ? (model.fixture?.transcript?.pending ?? "") : capture.pending
            )
            .region(.focal)

            Waveform(levels: showsFixture ? FakeAudioRecorder.designLevels : capture.levels,
                     lit: showsFixture ? 32 : nil, count: VoiceCapture.barCount, isStatic: showsFixture)
                .region(.wave)

            VoiceDock(
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
    private var session: MorningSession { model.morningSession }

    private var idea: StepIdea? {
        session.idea ?? (model.fixture != nil ? Fixtures.stepIdea(for: id) : nil)
    }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            subject.region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                if idea == nil, model.fixture == nil {
                    StepIdeaLoading(title: "Finding a step…")
                } else if let idea {
                    CompassText(idea.title, style: .title)
                    let part = model.part(idea.partID)
                    HStack(alignment: .top, spacing: Space.xs) {
                        if let part { Icon(CompassIcon(part.symbol), size: IconSize.s) }
                        CompassText(MorningRules.planMeta(partTitle: part?.title, hint: idea.hint, stepsThisWeek: model.ritualStepsThisWeek(idea.partID)),
                                    style: .caption, color: .ink3)
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
            SubjectLine(text: model.morningPlanningSubject, redoLabel: "Say your intention again") {
                model.startMorningListening(.intention)
            }
        } else {
            SubjectLine(text: model.goal?.text ?? "")
        }
    }
}

// MARK: - B4 · First week

/// No history yet, so you name the step: "What's one step today?" with the voice dock.
struct MorningNameStepView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { model.morningSession }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            if model.today?.intention != nil {
                SubjectLine(text: model.morningPlanningSubject, redoLabel: "Say your intention again") {
                    model.startMorningListening(.intention)
                }
                .region(.subject)
            } else {
                SubjectLine(text: model.goal?.text ?? "").region(.subject)
            }

            CompassText(MorningSession.Purpose.step.question, style: .title)
                .region(.focal)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.step) }
            } else {
                VoiceDock(
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
    private var session: MorningSession { model.morningSession }

    @State private var text = ""
    @State private var partID: UUID?
    @State private var pickingPart = false
    @FocusState private var focused: Bool

    private var purpose: MorningSession.Purpose { session.purpose ?? .step }
    private var isFixture: Bool { model.fixture != nil }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, trailing: skip, scalesText: true).region(.nav)

            SubjectLine(text: purpose == .step ? model.morningPlanningSubject : (model.goal?.text ?? ""))
                .region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                UnderlineField(prompt: purpose.question, text: $text, style: .title, focused: $focused, showsFocus: isFixture,
                               label: purpose == .step ? "Today’s step" : purpose.question, onSubmit: save)
                if purpose == .step, model.goal != nil {
                    let part = model.part(partID)
                    Chip(title: part?.title ?? "Choose a part", icon: part.map { CompassIcon($0.symbol) }, iconTint: .ink,
                         trailing: .down, accessibilityLabel: part.map { "Counts toward \($0.title). Change" } ?? "Choose a part") {
                        focused = false
                        pickingPart = true
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
        .partPickerSheet(isPresented: $pickingPart, parts: model.goal?.activeParts ?? [], selected: partID) { id in
            partID = id
            session.draftPartID = id
        }
        .onAppear {
            if isFixture && session.purpose == nil {
                text = Fixtures.workStepTitle
                partID = model.morningDefaultPartID
            } else {
                text = session.draft
                partID = session.draftPartID ?? model.morningDefaultPartID
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    /// Skip, as on B1 and B7's docks, when the intention or why is typed (live only; B5's board is a step).
    private var skip: NavItem? {
        guard !isFixture else { return nil }
        switch purpose {
        case .intention: return .text("Skip") { focused = false; Task { await model.continueToPlanning() } }
        case .why: return .text("Skip") { focused = false; model.skipWhy() }
        case .step: return nil
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
            // A spoken answer that didn't become words keeps its recording with the typed words.
            model.saveWhy(tidy, recording: session.whyRecording)
            session.whyRecording = nil
            model.replace(with: .b1)
        }
    }
}

/// B3 / B6 / F1 while the step idea is on its way (cloud help can take a few seconds): the question
/// greyed in the focal slot, as when listening, so the frame never sits empty. "Say my own step" stays.
struct StepIdeaLoading: View {
    let title: String

    var body: some View {
        CompassText(title, style: .title, color: .ink2)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - B7 · Day 3: why it matters

struct MorningWhyView: View {
    @Environment(AppModel.self) private var model
    private var session: MorningSession { model.morningSession }

    var body: some View {
        FlowScreen {
            NavBar(leading: model.morningClose, scalesText: true).region(.nav)

            SubjectLine(text: model.goal?.text ?? "").region(.subject)

            VStack(alignment: .leading, spacing: Space.s) {
                CompassText(MorningSession.Purpose.why.question, style: .title)
                CompassText("You’ll hear your answer on hard days.", color: .ink2)
            }
            .region(.focal)

            if let problem = ritualMicProblem(model, session.micProblem) {
                TypeInsteadDock(reason: problem) { model.openMorningTyping(.why) }
            } else {
                VoiceDock(
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
