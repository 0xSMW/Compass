import Foundation
import Observation
import UserNotifications
import CompassCore

/// What onboarding has collected so far (A2–A7). One per process; cleared when onboarding finishes
/// or starts over. Launching with `-screen <ID>` seeds it with that board's state.
@MainActor
@Observable
final class OnboardingDraft {
    static let shared = OnboardingDraft(seed: LaunchOptions.parse().screen)

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
        restoreSummary = nil
        restoreProgress = 0
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

// MARK: - Voice capture (A3)

/// Listens for the goal (or the A4b answer): words land as said, stops on silence (the transcriber
/// finishes its stream), or when the user taps stop. Drives the waveform from the recorder's levels.
@MainActor
@Observable
final class OnboardingVoiceCapture {
    var settled = ""
    var pending = ""
    var levels: [Float] = []
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var onFinish: (@MainActor (String) -> Void)?
    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var restoreScript: (() -> Void)?

    var text: String { TranscriptUpdate(settled: settled, pending: pending).text }

    func start(model: AppModel, script: String, onFinish: @escaping @MainActor (String) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.onFinish = onFinish
        let recorder = model.recorder
        let transcriber = model.transcriber
        self.recorder = recorder
        // The fakes stand in until the on-device recogniser lands: give them the board's words for
        // this question, and pace them so words visibly land.
        var paced = false
        if let fake = transcriber as? FakeSpeechTranscriber {
            let old = fake.script
            fake.script = script
            restoreScript = { fake.script = old }
            paced = !model.launch.uiTest
        }
        let pace = paced
        task = Task { [weak self] in
            var recording = false
            do {
                try await recorder.start()
                recording = true
            } catch {
                recording = false
            }
            if recording {
                self?.levelTask = Task { [weak self] in
                    for await level in recorder.levels() {
                        if Task.isCancelled { break }
                        self?.push(level)
                        if pace { try? await Task.sleep(nanoseconds: 60_000_000) }
                    }
                }
            }
            do {
                for try await update in transcriber.live() {
                    if Task.isCancelled { break }
                    self?.settled = update.settled
                    self?.pending = update.pending
                    if update.isFinal { break }
                    if pace { try? await Task.sleep(nanoseconds: 160_000_000) }
                }
            } catch {
                // Permission or recognition failure: keep whatever landed; the review screen lets them type.
            }
            if Task.isCancelled { return }
            self?.finish()
        }
    }

    private func push(_ level: Float) {
        levels.append(level)
        if levels.count > 38 { levels.removeFirst(levels.count - 38) }
    }

    /// Stop now (the stop button) and hand over what was said.
    func finish() {
        guard isRunning else { return }
        let words = text
        teardown()
        onFinish?(words)
        onFinish = nil
    }

    /// Leave without using the words (back, switching to the keyboard).
    func cancel() {
        guard isRunning else { return }
        teardown()
        onFinish = nil
    }

    private func teardown() {
        isRunning = false
        task?.cancel()
        levelTask?.cancel()
        task = nil
        levelTask = nil
        restoreScript?()
        restoreScript = nil
        if let recorder {
            Task { _ = try? await recorder.stop() }
        }
        recorder = nil
    }
}

// MARK: - Restore service hook

/// Where R1 looks for a backup. The iCloud sync owner sets `live` to its `BackupRestoring`
/// implementation at launch; until then iCloud reads as unavailable (R3).
@MainActor
enum OnboardingRestoreService {
    static var live: BackupRestoring = OnboardingNoBackup()
}

/// Live default before iCloud restore is wired: nothing to restore.
final class OnboardingNoBackup: BackupRestoring, @unchecked Sendable {
    func availability() async -> BackupAvailability { .nothing(.iCloudUnavailable) }
    func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot {
        throw RestoreError.iCloudUnavailable
    }
    func cancel() {}
}

/// The fixture restorer, paced so the bar visibly fills outside screenshots.
final class OnboardingPacedBackup: BackupRestoring, @unchecked Sendable {
    let base: FakeBackupRestoring
    let delay: UInt64

    init(base: FakeBackupRestoring, delay: TimeInterval) {
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

// MARK: - Notifications (A6)

enum OnboardingNotifications {
    static let morningID = "compass.rhythm.morning"
    static let eveningID = "compass.rhythm.evening"

    /// One notification at each moment, nothing else. Morning shows the goal (I5).
    static func schedule(rhythm: Rhythm, goalText: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [morningID, eveningID])
        func request(_ id: String, body: String, at time: TimeOfDay) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.body = body
            content.sound = nil
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: time.hour, minute: time.minute), repeats: true)
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }
        center.add(request(morningID, body: goalText, at: rhythm.morning)) { _ in }
        center.add(request(eveningID, body: "What did you do today?", at: rhythm.evening)) { _ in }
    }
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

    /// Mic and speech permission, asked the first time the user taps the mic (A2, A4b, "Say it again").
    func onboardingVoiceAllowed() async -> Bool {
        var mic = recorder.permission
        if mic == .notDetermined { mic = await recorder.requestPermission() }
        var speech = transcriber.permission
        if mic == .granted, speech == .notDetermined { speech = await transcriber.requestPermission() }
        conditions.microphone = mic
        conditions.speech = speech
        return mic == .granted && speech == .granted
    }

    /// A6 "Allow notifications": the system prompt, at the moment the times are on screen.
    func onboardingRequestNotifications() async -> Bool {
        if fixture != nil {
            let granted = conditions.notifications != .denied
            conditions.notifications = granted ? .granted : .denied
            return granted
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
        conditions.notifications = granted ? .granted : .denied
        return granted
    }

    /// A7 Start: save the goal and settings, then land by the clock (Center before noon,
    /// a step in the afternoon, "What did you do today?" after 21:00).
    func onboardingFinish(_ draft: OnboardingDraft) {
        let goal = draft.makeGoal(createdAt: now)
        setGoal(goal)
        updateSettings { s in
            s.rhythm = draft.rhythm
            s.cloudAssist = draft.cloudAssist
            s.notificationsEnabled = draft.notificationsEnabled
            s.input = draft.usedVoice ? .voice : .typing
        }
        if let fake = cloud as? FakeCloudAssist { fake.isEnabled = draft.cloudAssist }
        if fixture == nil, draft.notificationsEnabled {
            OnboardingNotifications.schedule(rhythm: draft.rhythm, goalText: goal.text)
        }
        draft.reset()
        goToEntry()
    }

    /// The restorer R1 talks to: the board's fake under `-screen`, the iCloud one otherwise.
    var onboardingBackup: BackupRestoring {
        guard fixture != nil else { return OnboardingRestoreService.live }
        return OnboardingPacedBackup(base: FakeBackupRestoring(conditions: conditions), delay: launch.uiTest ? 0 : 0.35)
    }

    /// Adopt a restored snapshot as this iPhone's data.
    func onboardingAdopt(_ restored: CompassSnapshot) {
        snapshot = restored
        updateSettings { _ in }
    }
}
