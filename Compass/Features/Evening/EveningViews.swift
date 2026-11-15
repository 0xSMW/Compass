import SwiftUI
import CompassCore

// MARK: - D1 · Step still open · D1L · Long step · D2 · No step planned · D7 · Largest text

/// Subject above, question at 224, two answers on 712. At AX the circles become full-width buttons
/// (`ChoiceCircles` does that): Done keeps the 712 line, Not today sits above it.
struct EveningQuestionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasStep = model.today?.step != nil
        let kind: EveningKind = hasStep ? .stepOpen : .noStep
        let subject = model.eveningSubject(kind: kind)
        FlowScreen {
            NavBar(leading: .close { model.closeEvening() }, scalesText: true).region(.nav)

            RitualSubject(icon: subject.icon, text: subject.text).region(.subject)

            Text(hasStep ? "Did you do it?" : "Did you move toward it today?")
                .ritualFont(.title)
                .fixedSize(horizontal: false, vertical: true)
                .region(.focal)

            ChoiceCircles(
                yes: hasStep ? "Done" : "Yes",
                no: "Not today",
                onYes: { model.answerEvening(.moved, kind: kind) },
                onNo: { model.answerEvening(.notToday, kind: kind) }
            )
            .region(.dock)
        }
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

            RitualSubject(icon: subject.icon, text: subject.text).region(.subject)

            Text(ReflectionRules.question(outcome: .moved, kind: .doneEarlier))
                .ritualFont(.title)
                .fixedSize(horizontal: false, vertical: true)
                .region(.focal)

            RitualVoiceDock(
                micMode: .rings,
                micLabel: "Speak",
                onKeyboard: { model.addToDoneEarlier(typing: true) },
                onMic: { model.addToDoneEarlier(typing: false) }
            )
            .region(.dock)
        }
    }
}

// MARK: - D3 · Reflect after Done · D3L · Long reflection · D4 · Reflect after Not today

/// The question greys; your words land under it and scroll up under a fade once they reach 592.
/// Keyboard switches to typing in the same place; with the microphone off or storage full the
/// I1/I4 notice and "Type instead" take the dock.
struct EveningReflectView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    @Bindable private var session = EveningSession.shared
    @FocusState private var focused: Bool
    private var capture: VoiceCapture { .shared }

    private var outcome: ReflectionOutcome { session.outcome ?? (id == .d4 ? .notToday : .moved) }
    private var kind: EveningKind { session.kind ?? (model.today?.step == nil ? .noStep : .stepOpen) }
    private var question: String { ReflectionRules.question(outcome: outcome, kind: kind) }
    private var showsFixture: Bool { model.fixture != nil && !capture.isBusy && !session.typing && session.micProblem == nil }

    var body: some View {
        let subject = model.eveningSubject(kind: kind)
        FlowScreen {
            NavBar(leading: .ritualClose("Close and keep what was said") { model.closeEveningKeeping() }, scalesText: true).region(.nav)

            RitualSubject(icon: subject.icon, text: subject.text).region(.subject)

            if session.typing {
                typing
            } else if let problem = session.micProblem {
                Text(question)
                    .ritualFont(.title)
                    .fixedSize(horizontal: false, vertical: true)
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

        ListeningWave(levels: showsFixture ? FakeAudioRecorder.designLevels : capture.levels, isStatic: showsFixture)
            .region(.wave)

        RitualVoiceDock(
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
            Text(question)
                .ritualFont(.title)
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
            UnderlineField(prompt: "Type it here", text: $session.draft, style: .live, focused: $focused)
                .accessibilityLabel(question)
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

    @Bindable private var session = EveningSession.shared
    @State private var expanded: Bool
    @State private var summaryDraft = ""
    @FocusState private var focused: Bool
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

            RitualSubject(icon: subject.icon, text: subject.text).region(.subject)

            if let r = model.today?.reflection {
                if session.editingSummary {
                    editor
                } else {
                    saved(r)
                }
            }
        }
        .task {
            guard model.fixture == nil, !session.working, let r = model.today?.reflection,
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
            Text(title)
                .ritualFont(.title)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: title)

            HStack(alignment: .top, spacing: Space.s) {
                if let goal = model.goal {
                    PartPickerChip(parts: goal.activeParts, selected: model.part(r.partID)) { model.setReflectionPart($0.id) }
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
                            Text(r.transcript)
                                .compassFont(.body)
                                .foregroundStyle(.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
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
        UnderlineField(prompt: "Summary", text: $summaryDraft, style: .title, focused: $focused)
            .accessibilityLabel("Summary")
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
                Text("Transcript")
                    .compassFont(.body)
                    .foregroundStyle(.ink)
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
        Button(action: action) {
            Icon(.pen, size: dts.isAccessibilitySize ? IconSize.s : IconSize.xs)
                .foregroundStyle(.ink2)
                .frame(width: ControlSize.minTarget, height: ControlSize.minTarget)
                .overlay(Circle().strokeBorder(Color.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Edit summary")
    }
}

/// D6: the summary waits, audio is safe. Icon, text and "Try now" on one row.
struct OfflineNotice: View {
    var working: Bool = false
    let onTry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.xs) {
            Icon(.cloud, size: IconSize.s).foregroundStyle(.ink2)
            Text("Offline. Text and summary appear here when you reconnect.")
                .compassFont(.caption)
                .foregroundStyle(.noticeInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onTry) {
                Text("Try now")
                    .compassFont(.body, weight: .medium)
                    .foregroundStyle(.ink)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 48)
            }
            .buttonStyle(PressableStyle())
            .disabled(working)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// D6b: retry, or type it; the recording stays either way.
struct TextFailedNotice: View {
    var working: Bool = false
    let onRetry: () -> Void
    let onType: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Couldn’t turn this recording into text.")
                .compassFont(.caption)
                .foregroundStyle(.noticeInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                Button(action: onRetry) {
                    Text("Try again").compassFont(.body, weight: .medium).foregroundStyle(.ink)
                        .padding(.trailing, 12).frame(minHeight: 48)
                }
                .buttonStyle(PressableStyle())
                .disabled(working)
                Button(action: onType) {
                    Text("Type a summary").compassFont(.body, weight: .medium).foregroundStyle(.ink)
                        .padding(.horizontal, 12).frame(minHeight: 48)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
