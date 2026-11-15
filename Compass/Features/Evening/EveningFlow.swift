import Foundation
import Observation
import CompassCore

/// Transient state of tonight's look-back, shared by D1–D6b as they replace each other in place.
/// Fixture launches start fresh, so each screen falls back to its board state.
@MainActor
@Observable
final class EveningSession {
    /// Which question opened the evening (decides the subject symbol and the reflect prompt).
    var kind: EveningKind?
    var outcome: ReflectionOutcome?
    /// Typing instead of speaking (keyboard on the dock, or "Type instead").
    var typing = false
    var draft = ""
    /// Recording that was running when the user switched to typing; kept with the typed words.
    var pendingRecording: Recording?
    /// Set when recording couldn't start; the reflect screen shows the I1 / I4 notice and "Type instead".
    var micProblem: VoiceCapture.StartError?
    /// Editing the summary (pen on D5, "Type a summary" on D6b).
    var editingSummary = false
    /// Transcription or summary in flight.
    var working = false
    /// The day this evening belongs to, fixed when its first screen appears. An answer finished after
    /// midnight still saves to that day, and the saved screen keeps showing it.
    var dayKey: DayKey?

    func reset() {
        dayKey = nil
        kind = nil
        outcome = nil
        typing = false
        draft = ""
        pendingRecording = nil
        micProblem = nil
        editingSummary = false
        working = false
    }
}

// MARK: - Evening actions

extension AppModel {
    /// The day tonight's answer is for (see `EveningSession.dayKey`).
    var eveningDayKey: DayKey { eveningSession.dayKey ?? todayKey }
    var eveningDay: Day? { snapshot.day(eveningDayKey) }

    /// D1 / D2 / D2b appeared: this evening belongs to today.
    func beginEvening() {
        let session = eveningSession
        if session.dayKey == nil { session.dayKey = todayKey }
    }

    /// "Start with: Typing" (Settings): answers open in the typing state instead of listening.
    var prefersTyping: Bool { fixture == nil && settings.input == .typing }

    /// The evening subject never changes: today's step (with its part, or ✓ when done earlier),
    /// or the goal when there was no step.
    func eveningSubject(kind: EveningKind) -> (icon: CompassIcon?, text: String) {
        if let step = eveningDay?.step {
            if kind == .doneEarlier { return (.ok, step.title) }
            return (part(step.partID).map { CompassIcon($0.symbol) }, step.title)
        }
        return (nil, goal?.text ?? "")
    }

    /// Done / Not today (D1, D7) or Yes / Not today (D2): the tapped circle becomes the mic.
    func answerEvening(_ outcome: ReflectionOutcome, kind: EveningKind) {
        let session = eveningSession
        let day = eveningDayKey
        session.reset()
        session.dayKey = day
        session.kind = kind
        session.outcome = outcome
        if outcome == .moved, kind == .stepOpen, eveningDay?.step?.isDone == false {
            let now = self.now
            updateDay(day) { $0.step?.completedAt = now }
        }
        if prefersTyping {
            session.typing = true
            replace(with: eveningReflectScreen)
        } else {
            startEveningListening()
        }
    }

    /// D2b: "Anything to add?" — mic or keyboard.
    func addToDoneEarlier(typing: Bool) {
        let session = eveningSession
        let day = eveningDayKey
        session.reset()
        session.dayKey = day
        session.kind = .doneEarlier
        session.outcome = .moved
        if typing {
            session.typing = true
            replace(with: .d3)
        } else {
            startEveningListening()
        }
    }

    var eveningReflectScreen: ScreenID { eveningSession.outcome == .notToday ? .d4 : .d3 }

    func startEveningListening() {
        let session = eveningSession
        session.micProblem = nil
        session.typing = false
        let target = eveningReflectScreen
        Task {
            do {
                guard try await voice.start(recorder: recorder, transcriber: transcriber) else { return }
            } catch let problem as VoiceCapture.StartError {
                session.micProblem = problem
            } catch {
                session.micProblem = .unavailable
            }
            replace(with: target)
        }
    }

    /// Stop (tap or silence) on D3/D4: save at once ("Saved"), then the summary takes the question's place.
    func finishEveningListening() async {
        let capture = voice
        guard capture.isListening else { return }
        let take = await capture.stop()
        saveEveningTake(transcript: take.transcript, recording: take.recording, transcriptionFailed: take.transcriptionFailed)
        replace(with: .d5)
        await refreshReflection()
    }

    /// Keyboard while listening: stop, keep the audio, and carry the words into the field.
    func switchEveningToTyping() {
        let session = eveningSession
        Task {
            if voice.isBusy {
                let take = await voice.stop()
                session.pendingRecording = take.recording
                session.draft = take.transcript
            }
            session.micProblem = nil
            session.typing = true
        }
    }

    /// Save on the typing state.
    func saveTypedReflection(_ text: String) {
        let session = eveningSession
        saveEveningTake(transcript: text, recording: session.pendingRecording, transcriptionFailed: false)
        session.typing = false
        session.pendingRecording = nil
        replace(with: .d5)
        Task { await refreshReflection() }
    }

    func saveEveningTake(transcript: String, recording: Recording?, transcriptionFailed: Bool) {
        let session = eveningSession
        let old = eveningDay?.reflection
        let reflection = ReflectionRules.draft(
            outcome: session.outcome ?? old?.outcome ?? .moved,
            transcript: transcript,
            recording: recording,
            transcriptionFailed: transcriptionFailed,
            partID: old?.partID ?? eveningDay?.step?.partID,
            now: now
        )
        if let oldFile = old?.audioFileName, oldFile != reflection.audioFileName {
            VoicePlayback.shared.stop()
            VoiceStorage.shared.delete(oldFile)
        }
        updateDay(eveningDayKey) { $0.reflection = reflection }
        Feedback.announce("Saved")
    }

    /// Words from the saved audio if needed (Try again, D6b), then a summary if cloud help is on.
    /// Offline → "Saved as audio." with the reconnect notice (D6). Off → the plain transcript.
    func refreshReflection() async {
        guard let start = eveningDay?.reflection else { return }
        let session = eveningSession
        session.working = true
        defer { session.working = false }
        let stamp = start.createdAt

        if ReflectionRules.needsTranscription(start), let file = start.audioFileName {
            let recording = Recording(duration: start.duration ?? 0, fileName: file, createdAt: start.createdAt)
            let text = try? await transcriber.transcribe(recording)
            updateReflection(createdAt: stamp) { ReflectionRules.applying(transcript: text, to: $0) }
        }

        guard let current = eveningDay?.reflection, current.createdAt == stamp, ReflectionRules.needsSummary(current) else { return }
        do {
            let summary = try await cloud.summarize(transcript: current.transcript, goal: goal)
            updateReflection(createdAt: stamp) { ReflectionRules.applying(summary: .success(summary), to: $0) }
        } catch {
            // Offline waits for the network (retried on reconnect, D6). Switch off, no endpoint, or a server
            // or decoding error keeps the plain transcript; those are never shown as "Offline".
            updateReflection(createdAt: stamp) { ReflectionRules.applying(summaryError: error, to: $0) }
        }
    }

    /// Apply a change to this evening's reflection if it is still the same one (the user may have redone it).
    func updateReflection(createdAt: Date? = nil, _ change: (Reflection) -> Reflection) {
        guard let r = eveningDay?.reflection else { return }
        if let createdAt, r.createdAt != createdAt { return }
        let next = change(r)
        updateDay(eveningDayKey) { $0.reflection = next }
    }

    func setReflectionPart(_ partID: UUID) {
        updateReflection { r in
            var r = r
            r.partID = partID
            return r
        }
    }

    func saveTypedSummary(_ text: String) {
        updateReflection { ReflectionRules.applying(typedSummary: text, to: $0) }
        eveningSession.editingSummary = false
    }

    /// Redo on the player: the same question again; the new memo replaces the old one.
    func recordReflectionAgain() {
        let session = eveningSession
        let day = eveningDayKey
        let outcome = eveningDay?.reflection?.outcome ?? .moved
        let kind = session.kind ?? (eveningDay?.step == nil ? .noStep : .stepOpen)
        session.reset()
        session.dayKey = day
        session.kind = kind
        session.outcome = outcome
        startEveningListening()
    }

    /// Close on D3/D4: "Close and keep what was said".
    func closeEveningKeeping() {
        let session = eveningSession
        Task {
            if voice.isBusy {
                let take = await voice.stop()
                saveEveningTake(transcript: take.transcript, recording: take.recording, transcriptionFailed: take.transcriptionFailed)
                Task { await refreshReflection() }
            } else if session.typing, !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saveEveningTake(transcript: session.draft, recording: session.pendingRecording, transcriptionFailed: false)
            } else if let recording = session.pendingRecording {
                saveEveningTake(transcript: "", recording: recording, transcriptionFailed: true)
            } else if session.outcome != nil, eveningDay?.reflection == nil {
                // The answer itself (Done / Not today) is kept even with nothing said.
                saveEveningTake(transcript: "", recording: nil, transcriptionFailed: false)
            }
            closeEvening()
        }
    }

    func closeEvening() {
        VoicePlayback.shared.stop()
        eveningSession.reset()
        closeRitual()
    }
}
