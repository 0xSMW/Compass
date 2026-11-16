import SwiftUI
import CompassCore

// MARK: - D1 · Step still open · D1L · Long step · D2 · No step planned · D7 · Largest text

/// Subject above, question at 224, two answers on 712. At AX the circles become full-width buttons
/// (`ChoiceCircles` does that): Done keeps the 712 line, Not today sits above it.
struct EveningQuestionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasStep = model.eveningDay?.step != nil
        let kind: EveningKind = hasStep ? .stepOpen : .noStep
        let subject = model.eveningSubject(kind: kind)
        FlowScreen {
            NavBar(leading: .close { model.closeEvening() }, scalesText: true).region(.nav)

            SubjectLine(icon: subject.icon, text: subject.text).region(.subject)

            CompassText(hasStep ? "Did you do it?" : "Did you move toward it today?", style: .title)
                .accessibilityAddTraits(.isHeader)
                .region(.focal)

            ChoiceCircles(
                yes: hasStep ? "Done" : "Yes",
                no: "Not today",
                onYes: { model.answerEvening(.moved, kind: kind) },
                onNo: { model.answerEvening(.notToday, kind: kind) }
            )
            .region(.dock)
        }
        .onAppear { model.beginEvening() }
    }
}

// MARK: - D2b · Done earlier

/// Already completed today, so only one question, with the voice dock.
struct EveningDoneEarlierView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let subject = model.eveningSubject(kind: .doneEarlier)
        FlowScreen {
            NavBar(leading: .close { model.closeEvening() }, scalesText: true).region(.nav)

            SubjectLine(icon: subject.icon, text: subject.text).region(.subject)

            CompassText(ReflectionRules.question(outcome: .moved, kind: .doneEarlier), style: .title)
                .accessibilityAddTraits(.isHeader)
                .region(.focal)

            VoiceDock(
                micMode: .rings,
                micLabel: "Speak",
                onKeyboard: { model.addToDoneEarlier(typing: true) },
                onMic: { model.addToDoneEarlier(typing: false) }
            )
            .region(.dock)
        }
        .onAppear { model.beginEvening() }
    }
}

// MARK: - D3 · Reflect after Done · D3L · Long reflection · D4 · Reflect after Not today

/// The question greys; your words land under it and scroll up under a fade once they reach 592.
/// Keyboard switches to typing in the same place; with the microphone off or storage full the
/// I1/I4 notice and "Type instead" take the dock.
struct EveningReflectView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    private var session: EveningSession { model.eveningSession }
    @State private var focused = false
    private var capture: VoiceCapture { model.voice }

    private var outcome: ReflectionOutcome { session.outcome ?? (id == .d4 ? .notToday : .moved) }
    private var kind: EveningKind { session.kind ?? (model.eveningDay?.step == nil ? .noStep : .stepOpen) }
    private var question: String { ReflectionRules.question(outcome: outcome, kind: kind) }
    private var showsFixture: Bool { model.fixture != nil && !capture.isBusy && !session.typing && micProblem == nil }
    /// Recording can't start (I4 storage full, microphone off): the notice and "Type instead" take the dock.
    private var micProblem: VoiceCapture.StartError? {
        if let problem = session.micProblem { return problem }
        return model.fixture != nil && !session.typing ? ritualMicProblem(model, nil) : nil
    }

    var body: some View {
        let subject = model.eveningSubject(kind: kind)
        FlowScreen {
            NavBar(leading: .close("Close and keep what was said") { model.closeEveningKeeping() }, scalesText: true).region(.nav)

            SubjectLine(icon: subject.icon, text: subject.text).region(.subject)

            if session.typing {
                typing
            } else if let problem = micProblem {
                CompassText(question, style: .title)
                    .accessibilityAddTraits(.isHeader)
                    .region(.focal)
                TypeInsteadDock(reason: problem) {
                    session.micProblem = nil
                    session.typing = true
                }
            } else {
                listening
            }
        }
        .onAppear {
            capture.onSilence = { Task { await model.finishEveningListening() } }
        }
    }

    @ViewBuilder
    private var listening: some View {
        ListeningFocal(
            question: question,
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
            onKeyboard: { model.switchEveningToTyping() },
            onMic: { Task { await model.finishEveningListening() } }
        )
        .region(.dock)
    }

    @ViewBuilder
    private var typing: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            CompassText(question, style: .title, color: .ink2)
            UnderlineField(prompt: "Type it here", text: Bindable(session).draft, style: .live, focused: $focused, label: question)
        }
        .region(.focal)
        .onAppear { if model.fixture == nil { DispatchQueue.main.async { focused = true } } }

        AboveKeyboardAction(
            title: "Save",
            enabled: !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.pendingRecording != nil
        ) {
            focused = false
            model.saveTypedReflection(session.draft)
        }
    }
}

// MARK: - D5 · Saved · D5L · Transcript open · D6 · Offline · D6b · Text failed · D8 · Largest text

/// The summary takes the question's place, the part chip and edit sit under it, the player takes
/// the mic's place on 712. Offline and failed-text states keep the same slots.
struct EveningSavedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    private var session: EveningSession { model.eveningSession }
    @State private var expanded: Bool
    @State private var summaryDraft = ""
    @State private var pickingPart = false
    @State private var focused = false
    private var playback: VoicePlayback { .shared }

    init(id: ScreenID) {
        self.id = id
        _expanded = State(initialValue: id == .d5L)
    }

    var body: some View {
        let subject = model.eveningSubject(kind: session.kind ?? .stepOpen)
        FlowScreen {
            NavBar(
                leading: .close { model.closeEvening() },
                trailing: session.editingSummary ? .text("Cancel") { session.editingSummary = false } : nil,
                scalesText: true
            )
            .region(.nav)

            SubjectLine(icon: subject.icon, text: subject.text).region(.subject)

            if let r = model.eveningDay?.reflection {
                if session.editingSummary {
                    editor
                } else {
                    saved(r)
                }
            }
        }
        .partPickerSheet(isPresented: $pickingPart, parts: model.goal?.activeParts ?? [],
                         selected: model.today?.reflection?.partID) { model.setReflectionPart($0) }
        .task {
            guard model.fixture == nil, !session.working, let r = model.eveningDay?.reflection,
                  ReflectionRules.needsSummary(r) else { return }
            await model.refreshReflection()
        }
    }

    @ViewBuilder
    private func saved(_ r: Reflection) -> some View {
        let title = ReflectionRules.title(for: r)
        let showsTranscript = ReflectionRules.showsTranscript(r)
        let open = expanded && showsTranscript
        VStack(alignment: .leading, spacing: 0) {
            CompassText(title, style: .title)
                .id(title)
                .transition(.opacity)
                .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: title)

            HStack(alignment: .top, spacing: Space.s) {
                if model.goal != nil {
                    let part = model.part(r.partID)
                    Chip(title: part?.title ?? "Choose a part", icon: part.map { CompassIcon($0.symbol) }, iconTint: .ink,
                         trailing: .down, accessibilityLabel: part.map { "Counts toward \($0.title). Change" } ?? "Choose a part") {
                        pickingPart = true
                    }
                }
                Spacer(minLength: 0)
                if ReflectionRules.canEdit(r) {
                    PenButton { startEditing(r) }
                }
            }
            .padding(.top, Space.s)

            switch r.summaryState {
            case .waitingForNetwork:
                OfflineNotice(working: session.working) { Task { await model.refreshReflection() } }
                    .padding(.top, Space.m)
            case .transcriptionFailed:
                TextFailedNotice(working: session.working,
                                 onRetry: { Task { await model.refreshReflection() } },
                                 onType: { startEditing(r) })
                    .padding(.top, Space.m)
            case .ready:
                if showsTranscript {
                    TranscriptRow(expanded: $expanded)
                        .padding(.top, dts.isAccessibilitySize ? Space.s : Space.m)
                    if open {
                        ScrollView {
                            CompassText(r.transcript, color: .ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Space.xs)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .mask(
                            LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .region(open ? .custom(top: 224, bottom: 648) : .focal)

        if let duration = r.duration {
            Player(
                duration: duration,
                isPlaying: playback.isPlaying(r.audioFileName),
                levels: playback.waveform(for: r.audioFileName) ?? Array(FakeAudioRecorder.designLevels.prefix(20)),
                onPlay: { playback.toggle(r.audioFileName) },
                onRedo: { model.recordReflectionAgain() }
            )
            .region(.player)
        }
    }

    @ViewBuilder
    private var editor: some View {
        UnderlineField(prompt: "Summary", text: $summaryDraft, style: .title, focused: $focused, label: "Summary")
            .region(.focal)
        AboveKeyboardAction(title: "Save", enabled: !summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            focused = false
            model.saveTypedSummary(summaryDraft)
        }
    }

    private func startEditing(_ r: Reflection) {
        summaryDraft = r.summary ?? r.transcript
        session.editingSummary = true
        DispatchQueue.main.async { focused = true }
    }
}

// MARK: - Saved-state pieces

/// kit.css `.lr` "Transcript ⌄" in ink; the chevron greys once open (⌃).
struct TranscriptRow: View {
    @Binding var expanded: Bool
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: Space.s) {
                // kit.css `.lr` sets ink after `.ink2`, so the label is ink; the chevron greys once open (`svg.ink2`).
                CompassText("Transcript").lineLimit(1)
                Spacer(minLength: 0)
                Icon(expanded ? .up : .down, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s)
                    .foregroundStyle(expanded ? Color.ink2 : Color.ink)
            }
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Transcript")
        .accessibilityValue(expanded ? "Open" : "Closed")
    }
}

/// kit.css `.ic44` with the 16pt pen (20 at AX): "Edit summary".
struct PenButton: View {
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        IconButton(.pen, label: "Edit summary", iconSize: dts.isAccessibilitySize ? IconSize.s : IconSize.xs, action: action)
    }
}

/// D6: the summary waits, audio is safe. Icon, text and "Try now" on one row.
struct OfflineNotice: View {
    var working: Bool = false
    let onTry: () -> Void

    var body: some View {
        Notice(icon: .cloud, text: "Offline. Text and summary appear here when you reconnect.",
               actions: [NoticeAction(title: "Try now", action: { if !working { onTry() } })], layout: .inline)
    }
}

/// D6b: retry, or type it; the recording stays either way.
struct TextFailedNotice: View {
    var working: Bool = false
    let onRetry: () -> Void
    let onType: () -> Void

    var body: some View {
        Notice(text: "Couldn’t turn this recording into text.",
               actions: [NoticeAction(title: "Try again", action: { if !working { onRetry() } }),
                         NoticeAction(title: "Type a summary", action: onType)],
               actionSpacing: Space.l, actionHeight: 48)
    }
}
