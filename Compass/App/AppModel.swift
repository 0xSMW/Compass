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
///
/// **One save path.** `snapshot` is read-only outside this file. Every change goes through
/// `mutate(_:)` (or `commit(_:origin:)` for a whole snapshot), which saves to the store, tells sync
/// about local changes and reloads the widget timelines. Never save the store directly.
@MainActor
@Observable
final class AppModel {
    // MARK: State

    private(set) var snapshot: CompassSnapshot
    var conditions: SystemConditions
    var calendar: Calendar
    /// Present when launched with `-screen`; carries transient state (live words, selected day).
    private(set) var fixture: ScreenFixture?
    /// The store file couldn't be read at launch (damaged, or from a newer Compass). It was copied aside;
    /// `StoreProblemAlert` tells the user. Set by the live path only.
    var storeProblem: StoreProblem? = nil
    let launch: LaunchOptions

    /// Screen stack; the last element is on screen.
    private(set) var path: [ScreenID]

    /// Clock bookkeeping for the live path (AppModel+Clock.swift): when the entry screen was last
    /// judged against the clock, and whether Today has a note or step being typed (the clock never
    /// pulls a screen away mid-sentence).
    @ObservationIgnored var entryCheckedAt: Date?
    @ObservationIgnored var isComposing = false

    // MARK: Services

    let store: Store
    let recorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let cloud: CloudAssist
    @ObservationIgnored private let clock: () -> Date
    /// What happens after every save (widget reload, sync notification). Spies replace it in tests.
    @ObservationIgnored let effects: SnapshotEffects

    init(launch: LaunchOptions = .parse()) {
        self.launch = launch
        effects = launch.screen == nil ? .live : .none
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
            // Never reads an unreadable or newer file as empty and overwrites it: it is copied aside first.
            let (loaded, problem) = fileStore.loadRecovering()
            storeProblem = problem
            snapshot = loaded
            conditions = .normal
            calendar = SharedStorage.calendar(for: loaded.settings)
            clock = { Date() }
            store = fileStore
            let voice = LiveVoiceServices.make() // LiveServices+Voice.swift
            recorder = voice.recorder
            transcriber = voice.transcriber
            cloud = LiveSync.makeCloudAssist(settings: loaded.settings)
            path = []
            path = [entryScreen]
            LiveSync.start(with: self)
        }
    }

    /// For unit tests: a live-path model (no fixture) on the given store, with fakes and a fixed clock.
    init(snapshot: CompassSnapshot, store: Store, calendar: Calendar, now: @escaping () -> Date,
         effects: SnapshotEffects, conditions: SystemConditions = .normal,
         recorder: AudioRecorder = FakeAudioRecorder(), transcriber: SpeechTranscriber = FakeSpeechTranscriber(),
         cloud: CloudAssist = FakeCloudAssist(isEnabled: false)) {
        launch = LaunchOptions()
        fixture = nil
        self.snapshot = snapshot
        self.conditions = conditions
        self.calendar = calendar
        clock = now
        self.store = store
        self.recorder = recorder
        self.transcriber = transcriber
        self.cloud = cloud
        self.effects = effects
        path = []
        path = [entryScreen]
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
        // Only a morning screen skips the morning (an evening closed after midnight leaves the new one open).
        if current.flow == .morning, case .morning = phase, !(today?.morningHandled ?? false) { skipMorning() }
        reset(to: ScreenID.entry(for: .today, today: today))
    }

    /// Recompute the entry screen (after the clock crosses noon/21:00 or data changes).
    func goToEntry() { reset(to: entryScreen) }

    /// Show `id` under whatever is pushed on top of the root (History, Settings), or on its own.
    func resetRoot(to id: ScreenID) {
        if path.count > 1 { path[0] = id } else { path = [id] }
    }

    // MARK: Saving (the only way to change the snapshot)

    /// Change the snapshot, then save, notify sync and reload the widget (if anything changed).
    func mutate(_ body: (inout CompassSnapshot) -> Void) {
        var next = snapshot
        body(&next)
        commit(next)
    }

    /// Replace the whole snapshot (restore, sync merge, the widget's copy) and save it.
    /// - `.local`: this device changed it, so sync pushes it as this device's change.
    /// - `.remote`: a merge from other devices; sync already knows, so it is not told again.
    func commit(_ next: CompassSnapshot, origin: SnapshotOrigin = .local) {
        // Local edits get per-item `updatedAt` and this device's id on new recordings, so sync merges
        // item by item (LiveServices+Sync.swift, CompassCore `LocalEdits`).
        let next = origin == .local ? LocalEdits.stamp(next, since: snapshot, at: now, device: deviceIdentity) : next
        guard next != snapshot else { return }
        snapshot = next
        save(origin: origin)
    }

    private func save(origin: SnapshotOrigin) {
        try? store.save(snapshot)
        if origin != .remote { effects.didChangeLocally() }
        effects.reloadWidgets()
    }

    func updateToday(_ body: (inout Day) -> Void) {
        let key = todayKey
        mutate { $0.updateDay(key, body) }
    }

    /// Change any day (History edits). Same save path as `updateToday`.
    func updateDay(_ key: DayKey, _ body: (inout Day) -> Void) {
        mutate { $0.updateDay(key, body) }
    }

    // MARK: Domain actions (shared by several flows)

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
        let ended: Goal? = snapshot.goal.flatMap { old in
            guard old.id != goal.id else { return nil }
            var ended = old
            if ended.status == .active { ended.status = .replaced }
            ended.endedAt = ended.endedAt ?? now
            return ended
        }
        mutate { s in
            if let ended { s.pastGoals.insert(ended, at: 0) }
            s.goal = goal
        }
    }

    func updateSettings(_ body: (inout Settings) -> Void) {
        mutate { body(&$0.settings) }
        calendar = SharedStorage.calendar(for: snapshot.settings)
        if fixture != nil, let tz = fixture?.calendar.timeZone, snapshot.settings.timeZoneID == nil { calendar.timeZone = tz }
    }

    /// Clear the snapshot here (H2 on this device, or a wipe from another device). The store file is
    /// removed and the widget reloads. Sync is told separately (`LiveSync.wipeEverywhere`), never as
    /// an ordinary local change, so an empty snapshot is not pushed over the wipe marker.
    func deleteEverything() {
        snapshot = .empty
        if let fileStore = store as? JSONFileStore { try? fileStore.deleteAll() } else { try? store.save(.empty) }
        effects.reloadWidgets()
        reset(to: .a1)
    }
}

/// Where a snapshot change came from (see `AppModel.commit`).
enum SnapshotOrigin: Equatable {
    case local
    case remote
    /// R2: a backup brought in on this device. Synced like a local change, but not stamped as made here.
    case restored
}

/// Side effects of a save. `.live` reloads the widget and tells iCloud sync; tests pass spies.
struct SnapshotEffects: Sendable {
    var reloadWidgets: @MainActor @Sendable () -> Void
    var didChangeLocally: @MainActor @Sendable () -> Void

    static let none = SnapshotEffects(reloadWidgets: {}, didChangeLocally: {})

    static let live = SnapshotEffects(
        reloadWidgets: {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStorage.widgetKind)
            #endif
        },
        didChangeLocally: { LiveSync.didChangeLocally() }
    )
}
