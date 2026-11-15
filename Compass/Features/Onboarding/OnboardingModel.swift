import Foundation
import Observation
import CompassCore

/// What onboarding has collected so far (A2–A7). One per `AppModel` (`model.onboardingDraft`);
/// cleared when onboarding finishes or starts over. Launching with `-screen <ID>` seeds it with that board's state.
@MainActor
@Observable
final class OnboardingDraft {
    /// The goal sentence as spoken or typed.
    var text = ""
    /// A4b: the one question for a vague goal (nil when concrete).
    var clarifyingQuestion: String?
    /// The question was asked (answered or kept as is). Asked once, never a block.
    var clarifyAsked = false
    /// A3 is listening for the A4b answer rather than the goal.
    var answering = false
    /// A5: proposed parts, editable.
    var parts: [GoalPart] = []
    /// The text the parts were proposed for (re-proposed when the goal changes).
    var partsSource = ""
    /// A6
    var rhythm = Rhythm.standard
    var notificationsEnabled = false
    /// A7: the one switch.
    var cloudAssist = true
    /// The goal came in by voice (sets the input preference).
    var usedVoice = false
    /// Setting a new goal over an existing one (G1, G2, F3, Today's "Set the next goal"): the rhythm,
    /// reminders, cloud help and input come from the current settings, and A6/A7 are skipped.
    var replacing = false
    /// R1/R2
    var restoreSummary: BackupSummary?
    var restoreProgress: Double = 0

    init(seed: ScreenID? = nil) {
        guard let seed else { return }
        switch seed {
        case .a4, .a4k, .a5, .a6, .a7:
            text = Fixtures.goalText
            parts = Fixtures.parts
            partsSource = Fixtures.goalText
            usedVoice = true
        case .a4b:
            text = Fixtures.vagueGoalText
            clarifyingQuestion = GoalShaper.clarifyingQuestion(for: Fixtures.vagueGoalText)
        case .r1:
            restoreSummary = BackupSummary(snapshot: Fixtures.restorableSnapshot)
            restoreProgress = 0.6
        case .r2:
            restoreSummary = BackupSummary(snapshot: Fixtures.restorableSnapshot)
            restoreProgress = 1
        default:
            break
        }
    }

    func reset() {
        text = ""
        clarifyingQuestion = nil
        clarifyAsked = false
        answering = false
        parts = []
        partsSource = ""
        rhythm = .standard
        notificationsEnabled = false
        cloudAssist = true
        usedVoice = false
        replacing = false
        restoreSummary = nil
        restoreProgress = 0
    }

    /// A new goal over an existing one keeps what the user already chose.
    func seed(from settings: Settings) {
        rhythm = settings.rhythm.clamped
        notificationsEnabled = settings.notificationsEnabled
        cloudAssist = settings.cloudAssist
        usedVoice = settings.input == .voice
        replacing = true
    }

    /// The A3 → A4 / A4b decision for captured words.
    /// Returns the screen to show next.
    func accept(captured raw: String, byVoice: Bool) -> ScreenID {
        let words = GoalShaper.normalize(raw)
        if byVoice { usedVoice = true }
        if answering {
            answering = false
            clarifyAsked = true
            if !words.isEmpty { text = words }
            return .a4
        }
        guard !words.isEmpty else { return .a2 }
        text = words
        if !clarifyAsked, let q = GoalShaper.clarifyingQuestion(for: words) {
            clarifyingQuestion = q
            return .a4b
        }
        return .a4
    }

    /// Continue on A4/A4k/A4b. Returns nil when there is nothing to continue with.
    func continueFromReview(on id: ScreenID) -> ScreenID? {
        let words = GoalShaper.normalize(text)
        guard !words.isEmpty else { return nil }
        text = words
        if id != .a4b, !clarifyAsked, let q = GoalShaper.clarifyingQuestion(for: words) {
            clarifyingQuestion = q
            return .a4b
        }
        clarifyAsked = true
        proposePartsIfNeeded()
        return .a5
    }

    func keepAsIs() {
        clarifyAsked = true
        text = GoalShaper.normalize(text)
        proposePartsIfNeeded()
    }

    /// A5 proposal, on the phone (nothing leaves it before the privacy step).
    func proposePartsIfNeeded() {
        guard partsSource != text || parts.isEmpty else { return }
        parts = GoalShaper.proposeParts(for: text)
        partsSource = text
    }

    func keepAsOnePart() {
        parts = GoalShaper.singlePart(for: text)
        partsSource = text
    }

    func updatePart(_ id: UUID, title: String, symbol: PartSymbol) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts[i].title = t }
        parts[i].symbol = symbol
    }

    func removePart(_ id: UUID) {
        guard parts.count > 1 else { return }
        parts.removeAll { $0.id == id }
    }

    /// The goal to save on Start (A7).
    func makeGoal(createdAt: Date) -> Goal {
        let sentence = GoalShaper.normalize(text)
        let finalParts = parts.isEmpty ? GoalShaper.singlePart(for: sentence) : parts
        return Goal(text: sentence, parts: finalParts, createdAt: createdAt)
    }
}

// MARK: - Restore pacing

/// The fixture restorer, paced so the bar visibly fills when clicking through fixtures by hand.
// @unchecked Sendable: only immutable lets; `base` is itself a Sendable BackupRestoring.
final class OnboardingPacedBackup: BackupRestoring, @unchecked Sendable {
    let base: BackupRestoring
    let delay: UInt64

    init(base: BackupRestoring, delay: TimeInterval) {
        self.base = base
        self.delay = UInt64(delay * 1_000_000_000)
    }

    func availability() async -> BackupAvailability { await base.availability() }

    func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot {
        let delay = self.delay
        let snapshot = try await base.restore { _ in }
        for step in 1...5 {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            progress(Double(step) / 5)
        }
        return snapshot
    }

    func cancel() { base.cancel() }
}

// MARK: - AppModel actions for onboarding and restore

extension AppModel {
    /// Back from any step-1 state (A3, A4, A4k, A4b turn-take in place over A2) returns to the question.
    func onboardingBack(from id: ScreenID) {
        switch id {
        case .a3, .a4, .a4k, .a4b:
            replace(with: .a2)
        default:
            if canGoBack { back() } else { reset(to: .a1) }
        }
    }

    /// A2 / A4b / "Say it again": start listening (VoiceCapture asks for mic and speech the first
    /// time), then turn to A3. Mic off or storage full → typing instead (A4k).
    func onboardingListen(answering: Bool, draft: OnboardingDraft, orType: @escaping @MainActor () -> Void) {
        if let fake = transcriber as? FakeSpeechTranscriber {
            // Fixture runs: the fake speaks the board's words for this question.
            fake.script = answering ? "Run twice a week, sleep by eleven and see friends every Sunday" : Fixtures.goalText
        }
        Task { @MainActor in
            do {
                guard try await voice.start(recorder: recorder, transcriber: transcriber) else { return }
                draft.answering = answering
                replace(with: .a3)
            } catch {
                orType()
            }
        }
    }

    /// A6 "Allow notifications": the system prompt, while the times are on screen.
    func onboardingRequestNotifications() async -> Bool {
        await requestNotificationPermission() == .granted
    }

    /// G1 "Replace with a new goal" / "Set a goal", G2 "Set the next goal", F3 "Set a new goal" and
    /// Today's "Set the next goal": the goal steps of onboarding (A2–A5), seeded from the current
    /// settings. A5 then saves the goal; the rhythm, reminders and cloud help stay as they are.
    func startNewGoal() {
        let draft = onboardingDraft
        draft.reset()
        draft.seed(from: settings)
        go(.a2)
    }

    /// A5 Continue: on to A6 for a first goal; a replacement goal is saved here (A6/A7 were chosen before).
    func onboardingContinueFromParts(_ draft: OnboardingDraft) {
        if draft.parts.isEmpty { draft.keepAsOnePart() }
        if draft.replacing { onboardingFinish(draft) } else { go(.a6) }
    }

    /// A7 Start (A5 when replacing a goal): save the goal and settings, then land by the clock (Center
    /// before noon, a step in the afternoon, "What did you do today?" after 21:00). A replacement goal
    /// leaves the settings alone.
    func onboardingFinish(_ draft: OnboardingDraft) {
        let goal = draft.makeGoal(createdAt: now)
        // A backup that arrived mid-onboarding is already merged here: `setGoal` ends its goal and the new
        // one is current, history kept. One that hasn't arrived yet is handled the same way when it does
        // (the fresh goal is marked for sync, which puts it back on top of the backup's goal).
        let beforeAnyGoal = !draft.replacing && snapshot.goal == nil
        setGoal(goal)
        if beforeAnyGoal, fixture == nil { LiveSync.markFreshGoal(goal.id) }
        if !draft.replacing {
            updateSettings { s in
                s.rhythm = draft.rhythm.clamped
                s.cloudAssist = draft.cloudAssist
                s.notificationsEnabled = draft.notificationsEnabled
                s.input = draft.usedVoice ? .voice : .typing
            }
        }
        if let fake = cloud as? FakeCloudAssist { fake.isEnabled = settings.cloudAssist }
        if let http = cloud as? HTTPCloudAssist { http.switchOn = settings.cloudAssist }
        // setGoal/updateSettings saved, told sync and reloaded the widget; System reschedules the reminders.
        draft.reset()
        goToEntry()
    }

    /// The restorer R1 talks to: the user's iCloud live, the fixture fake under `-screen`.
    var onboardingBackup: BackupRestoring {
        guard fixture != nil, !launch.uiTest else { return backupRestorer }
        return OnboardingPacedBackup(base: backupRestorer, delay: 0.35)
    }
}
