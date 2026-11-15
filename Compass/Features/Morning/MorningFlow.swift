import Foundation
import Observation
import CompassCore

/// Transient state of this morning's ritual, shared by B1–B7 as they replace each other in place.
/// (Fixture launches start with a fresh session, so each screen falls back to its board state.)
@MainActor
@Observable
final class MorningSession {
    static let shared = MorningSession()

    /// What the listening (B2) and typing (B5) screens are for.
    enum Purpose: Equatable {
        /// "Who will you be today?" (B1 → B2)
        case intention
        /// "What's one step today?" (B3/B4/B6 → B2 → B5)
        case step
        /// "Why does this matter to you?" (B7)
        case why
    }

    var purpose: Purpose?
    /// The suggested step for B3 / B6.
    var idea: StepIdea?
    var loadingIdea = false
    /// Words carried into the typing screen (spoken step, or what was said before switching to typing).
    var draft: String = ""
    var draftPartID: UUID?
    /// Set when recording couldn't start; the dock becomes "Type instead".
    var micProblem: VoiceCapture.StartError?

    func reset() {
        purpose = nil
        idea = nil
        loadingIdea = false
        draft = ""
        draftPartID = nil
        micProblem = nil
    }
}

extension MorningSession.Purpose {
    var question: String {
        switch self {
        case .intention: "Who will you be today?"
        case .step: "What’s one step today?"
        case .why: "Why does this matter to you?"
        }
    }
}

// MARK: - Morning actions

extension AppModel {
    private var morningEngine: DayEngine { DayEngine(calendar: calendar) }

    /// How today plans (first week names its own step; otherwise the quietest part gets an idea).
    var morningPlan: MorningPlan? { morningEngine.morningPlan(at: now, snapshot: snapshot) }

    /// The part a new step counts toward unless the user picks another.
    var morningDefaultPartID: UUID? { morningEngine.defaultPartID(at: now, snapshot: snapshot) }

    func ritualStepsThisWeek(_ partID: UUID?) -> Int {
        guard let partID else { return 0 }
        return morningEngine.stepsThisWeek(partID: partID, snapshot: snapshot, today: todayKey)
    }

    /// Subject line for planning screens: the intention in quotes, else the goal.
    var morningPlanningSubject: String {
        if let intention = today?.intention?.text, !intention.isEmpty { return MorningRules.quoted(intention) }
        return goal?.text ?? ""
    }

    // MARK: Listening

    /// Mic on B1, B3, B4, B6, B7: start listening, then B2 takes over (turn-taking in place).
    func startMorningListening(_ purpose: MorningSession.Purpose) {
        let session = MorningSession.shared
        session.purpose = purpose
        session.micProblem = nil
        Task {
            do {
                guard try await VoiceCapture.shared.start(recorder: recorder, transcriber: transcriber) else { return }
                replace(with: .b2)
            } catch let problem as VoiceCapture.StartError {
                session.micProblem = problem
            } catch {
                session.micProblem = .unavailable
            }
        }
    }

    /// Stop on B2 (tap or silence): save what was said and move on.
    func finishMorningListening() async {
        let capture = VoiceCapture.shared
        guard capture.isListening else { return }
        let session = MorningSession.shared
        let purpose = session.purpose ?? .intention
        let take = await capture.stop()

        guard !take.transcriptionFailed else {
            // No words came out: the same question, typed. Audio of a wordless intention isn't kept.
            if purpose != .why { VoiceStorage.shared.delete(take.recording?.fileName) }
            openMorningTyping(purpose, draft: "")
            return
        }
        switch purpose {
        case .intention:
            setIntention(MorningRules.intention(from: take.transcript), duration: take.recording?.duration)
            VoiceStorage.shared.delete(take.recording?.fileName)
            Feedback.announce("Saved")
            await continueToPlanning()
        case .why:
            saveWhy(MorningRules.why(from: take.transcript), recording: take.recording)
            Feedback.announce("Saved")
            replace(with: .b1)
        case .step:
            VoiceStorage.shared.delete(take.recording?.fileName)
            session.draftPartID = session.draftPartID ?? session.idea?.partID ?? morningDefaultPartID
            openMorningTyping(.step, draft: MorningRules.stepTitle(from: take.transcript))
        }
    }

    /// Keyboard on a voice dock (or while listening): the same question, typed. Words said so far carry over.
    func openMorningTyping(_ purpose: MorningSession.Purpose, draft: String? = nil) {
        let session = MorningSession.shared
        session.purpose = purpose
        if purpose == .step, session.draftPartID == nil { session.draftPartID = session.idea?.partID ?? morningDefaultPartID }
        if VoiceCapture.shared.isBusy {
            Task {
                let take = await VoiceCapture.shared.stop()
                if purpose != .why { VoiceStorage.shared.delete(take.recording?.fileName) }
                session.draft = draft ?? take.transcript
                replace(with: .b5)
            }
        } else {
            session.draft = draft ?? ""
            replace(with: .b5)
        }
    }

    // MARK: Planning

    /// After the intention (or Skip on B1): first week names its own step (B4); otherwise the
    /// quietest part gets an idea (B3). No idea (cloud help off, offline) → name it yourself.
    func continueToPlanning() async {
        let session = MorningSession.shared
        guard let plan = morningPlan else { goToEntry(); return }
        switch plan.planning {
        case .nameYourOwn:
            replace(with: .b4)
        case .suggestion(_, .smaller):
            // After 1–2 quiet days: F1's frame ("Smaller than usual. It still counts.") fetches its own idea.
            replace(with: .f1)
        case .suggestion(let partID, let size):
            if let idea = await morningFetchIdea(partID: partID, size: size) {
                session.idea = idea
                replace(with: .b3)
            } else {
                replace(with: .b4)
            }
        }
    }

    /// B6 (and B3 opened without an idea): ask for one; fall back to B4.
    func loadMorningIdeaIfNeeded() {
        let session = MorningSession.shared
        guard fixture == nil, session.idea == nil, !session.loadingIdea else { return }
        session.loadingIdea = true
        Task {
            var partID = morningDefaultPartID
            var size = StepSize.regular
            if case .suggestion(let p, let s)? = morningPlan?.planning { partID = p ?? partID; size = s }
            let idea = await morningFetchIdea(partID: partID, size: size)
            session.loadingIdea = false
            if let idea { session.idea = idea } else { replace(with: .b4) }
        }
    }

    func morningFetchIdea(partID: UUID?, size: StepSize) async -> StepIdea? {
        guard let goal else { return nil }
        let recent = Array(snapshot.sortedDays.suffix(14))
        return try? await cloud.suggestStep(goal: goal, part: part(partID), size: size, recent: recent)
    }

    /// "Use this" (B3, B6).
    func useSuggestedStep(_ idea: StepIdea) {
        setStep(title: idea.title, partID: idea.partID, size: idea.size, source: .suggested)
        finishMorning()
    }

    /// "Add step" (B5).
    func addTypedStep(_ title: String, partID: UUID?) {
        let text = MorningRules.stepTitle(from: title)
        guard !text.isEmpty else { return }
        setStep(title: text, partID: partID, source: .user)
        finishMorning()
    }

    /// "No step today" (B3, B6, Skip on B4). Allowed: the evening asks if you moved anyway.
    func noStepToday() {
        if !(today?.morningHandled ?? false) { skipMorning() }
        finishMorning()
    }

    func finishMorning() {
        MorningSession.shared.reset()
        goToEntry()
    }

    // MARK: Intention and why

    func saveTypedIntention(_ text: String) {
        let tidy = MorningRules.intention(from: text)
        guard !tidy.isEmpty else { return }
        setIntention(tidy)
        Task { await continueToPlanning() }
    }

    /// B7 answer: kept on the goal and played back on hard days. The note keeps the recording's id,
    /// so its audio is `<note id>.m4a`.
    func saveWhy(_ text: String, recording: Recording?) {
        guard var g = goal else { return }
        g.why = Note(id: recording?.id ?? UUID(), text: text, duration: recording?.duration, createdAt: now, device: "This iPhone")
        g.whyAsked = true
        setGoal(g)
    }

    /// Skip on B7: asked once, never again.
    func skipWhy() {
        guard var g = goal else { return }
        g.whyAsked = true
        setGoal(g)
        replace(with: .b1)
    }

    /// Close (top-left) on any morning screen: keep a spoken intention if there was one, then Today.
    func closeMorning() {
        let session = MorningSession.shared
        Task {
            if VoiceCapture.shared.isBusy {
                let take = await VoiceCapture.shared.stop()
                VoiceStorage.shared.delete(take.recording?.fileName)
                if (session.purpose ?? .intention) == .intention, !take.transcript.isEmpty, today?.intention == nil {
                    setIntention(MorningRules.intention(from: take.transcript), duration: take.recording?.duration)
                }
            }
            session.reset()
            closeRitual()
        }
    }
}
