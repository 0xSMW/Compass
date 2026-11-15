import SwiftUI
import CompassCore

/// Today (C1–C11b, and I2/I3 which are Today with a notice). One view for every state: what's on screen
/// comes from today's data plus local interaction state, so completing, recording or typing never
/// changes the ScreenID and the anchors never move — card bottom 656, control 604, Note row 712.
/// Screenshots (`-screen C5` …) seed the transient state from the ID.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    enum TypingTarget: Equatable { case note, step }

    enum Mode: Equatable {
        case resting
        /// C5: the notes row becomes live words; the Note pill becomes the recorder.
        case recording
        /// C10: keyboard up, field rides on it.
        case typing(TypingTarget)
        /// C6: Step options sheet.
        case options
        /// C6 → Counts toward.
        case movePart
        /// All of today's notes.
        case notes
        /// One note: its words, its recording (plays as it opens), Edit note, Delete note.
        /// `editing`: a voice note just saved with no words opens on "Add words".
        case note(UUID, editing: Bool)
    }

    @State private var mode: Mode = .resting
    /// C4: "Done · Undo" in the label slot for 5 s after a tap.
    @State private var justDone = false
    @State private var undoTask: Task<Void, Never>?
    @State private var transcript: TranscriptUpdate?
    @State private var levels: [Float] = []
    /// Microphone off / storage full after tapping Note: shown in the notes row until fixed.
    @State private var showsRecordingBlock = false
    @State private var draft = ""
    @State private var configured = false
    @FocusState private var fieldFocused: Bool

    private var isFixture: Bool { model.fixture != nil }

    private var isTyping: Bool {
        if case .typing = mode { return true }
        return false
    }

    private var isSheetUp: Bool {
        switch mode {
        case .options, .movePart, .notes, .note: return true
        default: return false
        }
    }

    var body: some View {
        let today = model.today
        ZStack {
            TodayScaffold(
                onHistory: { model.go(.e1) },
                onSettings: { model.go(.h1) },
                // Typing a note (C10): the escape is a visible control where Settings sits (no hidden gestures).
                trailing: isTyping ? NavItem.text("Cancel", action: { cancelTyping() }) : nil,
                forceScrolledToEnd: id == .c11b && isFixture
            ) {
                header(today)
            } notes: {
                if !isTyping && !isSheetUp { notesRow(today) }
            } card: {
                if !isTyping { card(today) }
            } dock: {
                if !isTyping { dock }
            } overlay: {
                overlay(today)
            }

            if isTyping && !isFixture { liveTypingLayer }
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: mode)
        .onAppear(perform: configure)
        .onDisappear {
            undoTask?.cancel()
            if !isFixture { model.isComposing = false }
            if mode == .recording { Task { _ = await finishRecording(save: true) } }
        }
        .onChange(of: fieldFocused) { wasFocused, focused in
            // Keyboard dismissed (swipe, tap outside): leave typing, keep the draft for next time.
            if wasFocused, !focused, isTyping, !isFixture { mode = .resting }
        }
        .onChange(of: mode) { _, mode in
            // The clock never pulls Today away mid-sentence (AppModel+Clock.swift).
            if !isFixture { model.isComposing = isComposing(mode) }
        }
    }

    // MARK: Fixture states

    private func configure() {
        guard !configured else { return }
        configured = true
        guard isFixture else { return }
        switch id {
        case .c4: justDone = true
        case .c5:
            mode = .recording
            transcript = model.fixture?.transcript
            levels = Array(FakeAudioRecorder.designLevels.prefix(30))
        case .c6: mode = .options
        case .c10:
            mode = .typing(.note)
            draft = Fixtures.noteText
        default: break
        }
    }

    // MARK: Header (goal + intention, grows down from 128)

    private func header(_ today: Day?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let goal = model.goal {
                CompassText(goal.text, style: .title)
                    .accessibilityAddTraits(.isHeader)
            }
            if let intention = today?.intention {
                CompassText("“\(intention.text)”", color: .ink2)
                    .padding(.top, Space.s)
            }
        }
    }

    // MARK: Notes row (notes, live words and notices share it)

    @ViewBuilder
    private func notesRow(_ today: Day?) -> some View {
        if mode == .recording {
            LiveTranscript(settled: liveWords.settled, pending: liveWords.pending)
                .lineLimit(3)
                .truncationMode(.head)
                .accessibilityAddTraits(.updatesFrequently)
        } else if showsRecordingBlock, let block = RecordingBlock(model.conditions) {
            SystemRecordingNotice(block: block, showsAction: true) {
                switch block {
                case .microphoneOff: model.turnOnMicrophone()
                case .storageFull: model.openSystemSettings()
                }
            }
        } else if let change = model.timeZoneChange {
            SystemTimeZoneNotice(change: change, rhythm: model.settings.rhythm,
                                 onOK: { model.answerTimeZoneNotice(keepPrevious: false) },
                                 onKeep: { model.answerTimeZoneNotice(keepPrevious: true) })
        } else if model.showsNotificationsNotice {
            SystemNotificationsNotice(rhythm: model.settings.rhythm,
                                      onTurnOn: { model.turnOnNotifications() },
                                      onDismiss: { model.dismissNotificationsNotice() })
        } else if let notes = today?.notes, let latest = notes.last {
            // One note opens that note (it plays if it's a recording); several open the list.
            NoteRow(note: latest, count: notes.count) {
                mode = notes.count > 1 ? .notes : .note(latest.id, editing: false)
            }
        }
    }

    // MARK: Step card (grows up from 656, control at 604)

    @ViewBuilder
    private func card(_ today: Day?) -> some View {
        if let step = today?.step {
            let part = model.part(step.partID)
            StepCard(
                title: step.title,
                partTitle: part?.title,
                partIcon: part.map { CompassIcon($0.symbol) },
                state: step.isDone ? (justDone ? .justDone : .done) : .open,
                onToggle: { toggle($0) },
                onUndo: { undo() },
                onOptions: { mode = .options },
                showsOptions: !(mode == .options || mode == .movePart)
            )
            .allowsHitTesting(mode == .resting || mode == .recording)
        } else if !model.snapshot.hasActiveGoal {
            // The goal was achieved (or ended): Today keeps its frame and the card sets the next one.
            StepCard(
                title: "",
                state: .empty(title: model.goal?.status == .achieved ? "You arrived." : "No goal right now",
                              label: "Set the next goal"),
                onPlan: { model.startNewGoal() }
            )
        } else {
            StepCard(
                title: "",
                state: today?.intention == nil
                    ? .empty(title: "No step yet", label: "Add one step for today")
                    : .empty(title: "No step today", label: "You can still add one"),
                onPlan: { model.go(model.todayPlanningScreen) }
            )
        }
    }

    private func toggle(_ done: Bool) {
        undoTask?.cancel()
        model.setStepDone(done)
        justDone = done
        guard done else { return }
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { justDone = false }
        }
    }

    private func undo() {
        undoTask?.cancel()
        justDone = false
        model.setStepDone(false)
        Feedback.announce("Step reopened")
    }

    // MARK: Dock (keyboard + Note, 680–744)

    private var dock: some View {
        // "Start with: Typing" swaps the two: the pill types, the circle records.
        TodayDock(recording: mode == .recording, typingFirst: typingFirst, levels: pillLevels,
                  onKeyboard: keyboardTapped, onNote: noteTapped)
    }

    /// Settings › Start with: Typing.
    private var typingFirst: Bool { model.prefersTyping }

    private func isComposing(_ mode: Mode) -> Bool {
        switch mode {
        case .typing: return true
        case .note(_, let editing): return editing
        default: return false
        }
    }

    private var pillLevels: [Float] {
        let recent = Array((isFixture ? levels : capture.levels).suffix(30))
        return Array(repeating: Float(0.1), count: max(0, 30 - recent.count)) + recent
    }

    private func keyboardTapped() {
        if mode == .recording {
            Task {
                let spoken = await finishRecording(save: false)
                startTyping(.note, text: spoken)
            }
        } else {
            startTyping(.note, text: draft)
        }
    }

    private func noteTapped() {
        if mode == .recording {
            Task { _ = await finishRecording(save: true) }
        } else {
            Task { await startRecording() }
        }
    }

    // MARK: Recording (C5)

    /// The shared voice take (same recorder + on-device speech as the morning and evening).
    private var capture: VoiceCapture { model.voice }

    /// Live words in the notes row: the fixture's for screenshots, else the take's.
    private var liveWords: TranscriptUpdate {
        if isFixture { return transcript ?? TranscriptUpdate(settled: "") }
        return TranscriptUpdate(settled: capture.settled, pending: capture.pending)
    }

    private func startRecording() async {
        if await model.prepareToRecord() != nil {
            showsRecordingBlock = true
            return
        }
        showsRecordingBlock = false
        capture.onSilence = { Task { _ = await finishRecording(save: true) } }
        do {
            // false: a take was already starting, or this one was cancelled before it began.
            guard try await capture.start(recorder: model.recorder, transcriber: model.transcriber) else { return }
        } catch VoiceCapture.StartError.microphoneOff {
            model.conditions.microphone = .denied
            showsRecordingBlock = true
            return
        } catch VoiceCapture.StartError.storageFull {
            model.conditions.storageFull = true
            showsRecordingBlock = true
            return
        } catch {
            return
        }
        mode = .recording
    }

    /// Stop the take. Saves the note (words, audio and length) unless switching to typing; returns the
    /// words. The note keeps the recording's id, so its audio stays at `<note id>.m4a` and plays from
    /// the notes row and History. With no words (speech off, nothing recognised) the audio is kept and
    /// the note opens on "Add words".
    private func finishRecording(save: Bool) async -> String {
        guard mode == .recording else { return "" }
        capture.onSilence = nil
        let take = await capture.stop()
        mode = .resting
        guard save, let note = model.saveVoiceNote(transcript: take.transcript, recording: take.recording) else {
            // Switching to typing carries the words over; the audio isn't kept without a note.
            VoiceStorage.shared.delete(take.recording?.fileName)
            return take.transcript
        }
        Feedback.announce("Note saved")
        if NoteRules.needsWords(note) { mode = .note(note.id, editing: true) }
        return take.transcript
    }

    // MARK: Typing (C10, and Change step)

    private func startTyping(_ target: TypingTarget, text: String) {
        showsRecordingBlock = false
        draft = text
        mode = .typing(target)
        DispatchQueue.main.async { fieldFocused = true }
    }

    /// C10 Cancel: leave typing, keep the draft for next time.
    private func cancelTyping() {
        fieldFocused = false
        mode = .resting
    }

    private func saveTyping() {
        guard case .typing(let target) = mode else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .note: if !text.isEmpty { model.addNote(text) }
        case .step: model.todayRenameStep(text)
        }
        draft = ""
        mode = .resting
        fieldFocused = false
    }

    private var typingTarget: TypingTarget {
        if case .typing(let target) = mode { return target }
        return .note
    }

    private var noteField: some View {
        let step = typingTarget == .step
        return TodayNoteField(text: $draft,
                              prompt: step ? "Today’s step" : "Note",
                              label: step ? "Step" : "Note",
                              saveLabel: step ? "Save step" : "Save note",
                              focus: $fieldFocused) { saveTyping() }
    }

    /// Live: the field sits 16 above the real keyboard (the keyboard's safe area), whatever its height.
    private var liveTypingLayer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { fieldFocused = false; mode = .resting }
                .accessibilityHidden(true)
            noteField
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.s)
        }
    }

    // MARK: Overlays (sheets; the drawn keyboard in screenshots)

    @ViewBuilder
    private func overlay(_ today: Day?) -> some View {
        switch mode {
        case .options:
            if let step = today?.step {
                CompassSheet(height: TodayStepOptions.sheetHeight(rows: 3), label: "Step options", contentTop: Space.m,
                             onDismiss: { mode = .resting }) {
                    TodayStepOptions(
                        part: model.part(step.partID),
                        onChange: { startTyping(.step, text: step.title) },
                        onMove: { mode = .movePart },
                        onDelete: {
                            mode = .resting
                            model.deleteStep()
                            Feedback.announce("Step deleted")
                        }
                    )
                }
            }
        case .movePart:
            let parts = model.goal?.activeParts ?? []
            // One level in: Cancel goes back to the options.
            CompassSheet(height: TodayStepOptions.sheetHeight(rows: max(1, parts.count)), label: "Counts toward", contentTop: Space.m,
                         onDismiss: { mode = .options }) {
                PartPickerRows(parts: parts, selected: today?.step?.partID) { id in
                    if let id { model.todayMoveStep(to: id) }
                    mode = .resting
                }
            }
        case .notes:
            let notes = today?.notes ?? []
            CompassSheet(height: TodayStepOptions.sheetHeight(rows: max(1, notes.count)), label: "Today’s notes", dismissTitle: "Close",
                         contentTop: Space.m, onDismiss: { mode = .resting }) {
                TodayNotesList(notes: notes) { mode = .note($0.id, editing: false) }
            }
        case .note(let noteID, let editing):
            if let note = today?.notes.first(where: { $0.id == noteID }) {
                NoteDetailSheet(
                    note: note,
                    startsEditing: editing,
                    onSave: { text in
                        model.editNote(noteID, on: model.todayKey, text: text)
                        Feedback.announce("Note saved")
                        mode = .resting
                    },
                    onDelete: {
                        model.deleteNote(noteID, on: model.todayKey)
                        Feedback.announce("Note deleted")
                        mode = .resting
                    },
                    onClose: { mode = .resting }
                )
                .id(noteID)
            }
        case .typing where isFixture:
            ZStack(alignment: .top) {
                KeyboardPlaceholder().region(.keyboard)
                noteField
                    .region(.aboveKeyboard)
            }
        default:
            EmptyView()
        }
    }
}
