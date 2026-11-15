import Foundation
import Observation
import CompassCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app's single source of truth: the snapshot, the clock, system conditions, services and the
/// screen stack. Views read it with `@Environment(AppModel.self) private var model`.
///
/// Flow folders add their own actions as `extension AppModel` in their folder; keep this file to
/// shared state and cross-flow navigation.
@MainActor
@Observable
final class AppModel {
    // MARK: State

    var snapshot: CompassSnapshot
    var conditions: SystemConditions
    var calendar: Calendar
    /// Present when launched with `-screen`; carries transient state (live words, selected day).
    private(set) var fixture: ScreenFixture?
    let launch: LaunchOptions

    /// Screen stack; the last element is on screen.
    private(set) var path: [ScreenID]

    // MARK: Services

    let store: Store
    let recorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let cloud: CloudAssist
    @ObservationIgnored private let clock: () -> Date

    init(launch: LaunchOptions = .parse()) {
        self.launch = launch
        if let id = launch.screen {
            let f = Fixtures.fixture(for: id)
            fixture = f
            snapshot = f.snapshot
            conditions = f.conditions
            calendar = f.calendar
            let fixedNow = f.now
            clock = { fixedNow }
            store = InMemoryStore(f.snapshot)
            recorder = FakeAudioRecorder(permission: f.conditions.microphone, storageFull: f.conditions.storageFull)
            transcriber = FakeSpeechTranscriber(permission: f.conditions.speech, fails: f.conditions.transcriptionFails)
            cloud = FakeCloudAssist(isEnabled: f.snapshot.settings.cloudAssist, isOnline: f.conditions.online)
            path = [id]
        } else {
            fixture = nil
            let fileStore = SharedStorage.makeStore()
            let loaded = (try? fileStore.load()) ?? .empty
            snapshot = loaded
            conditions = .normal
            calendar = SharedStorage.calendar(for: loaded.settings)
            clock = { Date() }
            store = fileStore
            // Real AVAudioRecorder / SFSpeechRecognizer / cloud clients replace these fakes later.
            recorder = FakeAudioRecorder()
            transcriber = FakeSpeechTranscriber()
            cloud = LiveSync.makeCloudAssist(settings: loaded.settings)
            path = []
            path = [entryScreen]
            LiveSync.start(with: self)
        }
    }

    // MARK: Derived

    var now: Date { clock() }
    var todayKey: DayKey { DayKey(now, calendar: calendar) }
    var today: Day? { snapshot.day(todayKey) }
    var goal: Goal? { snapshot.goal }
    var settings: Settings { snapshot.settings }
    var phase: DayPhase { DayEngine(calendar: calendar).phase(at: now, snapshot: snapshot) }
    var history: HistoryBuilder { HistoryBuilder(calendar: calendar) }

    /// Where the live app opens for the current phase (Center before noon, a step in the
    /// afternoon, "What did you do today?" after 21:00).
    var entryScreen: ScreenID { ScreenID.entry(for: phase, today: today) }

    var current: ScreenID { path.last ?? entryScreen }
    var canGoBack: Bool { path.count > 1 }

    func part(_ id: UUID?) -> GoalPart? { goal?.part(id) }

    // MARK: Navigation

    /// Push a screen (History from Today, a day from History, Settings…).
    func go(_ id: ScreenID) { path.append(id) }

    /// Replace the current screen (turn-taking inside a flow: B1 → B2 → B3).
    func replace(with id: ScreenID) {
        if path.isEmpty { path = [id] } else { path[path.count - 1] = id }
    }

    /// Pop one screen. No-op at the root.
    func back() { if path.count > 1 { path.removeLast() } }

    /// Start a new stack (finishing onboarding, closing a ritual).
    func reset(to id: ScreenID) { path = [id] }

    /// Close (top-left) on a morning or evening screen: leave the ritual for Today.
    func closeRitual() {
        if case .morning = phase, !(today?.morningHandled ?? false) { skipMorning() }
        reset(to: ScreenID.entry(for: .today, today: today))
    }

    /// Recompute the entry screen (after the clock crosses noon/21:00 or data changes).
    func goToEntry() { reset(to: entryScreen) }

    // MARK: Domain actions (shared by several flows)

    func updateToday(_ body: (inout Day) -> Void) {
        snapshot.updateDay(todayKey, body)
        persist()
    }

    func skipMorning() { updateToday { $0.morningSkipped = true } }

    func setIntention(_ text: String, duration: TimeInterval? = nil) {
        updateToday { $0.intention = Intention(text: text, duration: duration, createdAt: now) }
    }

    func setStep(title: String, partID: UUID?, size: StepSize = .regular, source: StepSource = .user) {
        updateToday { $0.step = Step(title: title, partID: partID, createdAt: now, size: size, source: source) }
    }

    func deleteStep() { updateToday { $0.step = nil } }

    /// Complete or reopen today's step. Feedback (click, haptic, announcement) is the view's job
    /// (`CompletionCircle` does it).
    func setStepDone(_ done: Bool) {
        updateToday { $0.step?.completedAt = done ? now : nil }
    }

    func addNote(_ text: String, duration: TimeInterval? = nil) {
        updateToday { $0.notes.append(Note(text: text, duration: duration, createdAt: now, device: "This iPhone")) }
    }

    func saveReflection(_ reflection: Reflection) { updateToday { $0.reflection = reflection } }

    func setGoal(_ goal: Goal) {
        if let old = snapshot.goal, old.id != goal.id {
            var ended = old
            if ended.status == .active { ended.status = .replaced }
            ended.endedAt = ended.endedAt ?? now
            snapshot.pastGoals.insert(ended, at: 0)
        }
        snapshot.goal = goal
        persist()
    }

    func updateSettings(_ body: (inout Settings) -> Void) {
        body(&snapshot.settings)
        calendar = SharedStorage.calendar(for: snapshot.settings)
        if fixture != nil, let tz = fixture?.calendar.timeZone, snapshot.settings.timeZoneID == nil { calendar.timeZone = tz }
        persist()
    }

    /// H2: everything goes, on this iPhone and in iCloud.
    func deleteEverything() {
        snapshot = .empty
        if let fileStore = store as? JSONFileStore { try? fileStore.deleteAll() } else { persist() }
        reset(to: .a1)
    }

    private func persist() {
        try? store.save(snapshot)
        #if canImport(WidgetKit)
        if fixture == nil { WidgetCenter.shared.reloadTimelines(ofKind: SharedStorage.widgetKind) }
        #endif
    }
}
