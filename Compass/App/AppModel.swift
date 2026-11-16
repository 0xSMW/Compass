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
    /// The last save didn't reach the disk (full storage). What was added stays in memory and Today says
    /// so; the store file is older than memory, so it is never read back over it (`reloadFromStore`).
    /// Saving is retried on the next change and when the app becomes active.
    private(set) var saveFailed = false
    /// The store file's modification date right after this app last wrote (or read) it. A later date
    /// means another process (the widget) wrote it.
    @ObservationIgnored private(set) var lastSavedAt: Date?
    let launch: LaunchOptions

    /// Screen stack; the last element is on screen.
    private(set) var path: [ScreenID]

    /// Clock bookkeeping for the live path (AppModel+Clock.swift): when the entry screen was last
    /// judged against the clock, and whether Today has a note or step being typed (the clock never
    /// pulls a screen away mid-sentence).
    @ObservationIgnored var entryCheckedAt: Date?
    @ObservationIgnored var isComposing = false
    /// A merge's or a tapped reminder's move that waits for the answer in progress (AppModel+Clock.swift).
    @ObservationIgnored var pendingEntryMove: PendingEntryMove?

    // MARK: Session state (owned here, one per model, so tests never share it)

    /// The spoken answer in progress (intention, step, note, why, reflection, goal).
    let voice: VoiceCapture
    /// This morning's ritual (B1–B7) as its screens replace each other.
    let morningSession: MorningSession
    /// Tonight's look-back (D1–D6b).
    let eveningSession: EveningSession
    /// What onboarding has collected (A2–A7); seeded from the fixture under `-screen`.
    let onboardingDraft: OnboardingDraft
    /// A1's backup check and R3's reason.
    let restoreRouting: RestoreRouting
    /// The day, week or past goal History is showing.
    let historySelection: HistorySelection
    /// Permissions, time zone, reminders and the boundary timer on the live path (started by
    /// `.systemServices()`; never started for fixtures or unit tests).
    let system: SystemServices

    // MARK: Services

    let store: Store
    let recorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let cloud: CloudAssist
    @ObservationIgnored private let clock: () -> Date
    /// Moves the tap-through UI test's clock (`-tapthrough` only, Debug builds; DebugHarness.swift).
    @ObservationIgnored private(set) var moveHarnessClock: ((Date) -> Void)?
    /// What happens after every save (widget reload, sync notification). Spies replace it in tests.
    @ObservationIgnored let effects: SnapshotEffects

    init(launch: LaunchOptions = .parse()) {
        self.launch = launch
        voice = VoiceCapture()
        morningSession = MorningSession()
        eveningSession = EveningSession()
        onboardingDraft = OnboardingDraft(seed: launch.screen)
        restoreRouting = RestoreRouting()
        historySelection = HistorySelection()
        system = SystemServices()
        effects = launch.screen == nil && !launch.tapThrough ? .live : .none
        #if DEBUG
        let harness = LaunchHarness.setup(for: launch)
        #else
        let harness: HarnessSetup? = nil
        #endif
        if let harness {
            // `-screen` / `-tapthrough` (Debug only): fixtures or an empty in-memory store, the fakes and
            // a fixed or movable clock. Release builds never get here (DebugHarness.swift).
            fixture = harness.fixture
            snapshot = harness.snapshot
            conditions = harness.conditions
            calendar = harness.calendar
            clock = harness.clock
            moveHarnessClock = harness.moveClock
            store = harness.store
            recorder = harness.recorder
            transcriber = harness.transcriber
            cloud = harness.cloud
            path = harness.path
            #if DEBUG
            LaunchHarness.prepare(self)
            #endif
        } else {
            fixture = nil
            let fileStore = SharedStorage.makeStore()
            // Never reads an unreadable or newer file as empty and overwrites it: it is copied aside first.
            let (loaded, problem) = fileStore.loadRecovering()
            storeProblem = problem
            snapshot = loaded
            lastSavedAt = fileStore.modifiedAt
            AudioTombstoneLog.shared.noteReferenced(loaded.referencedAudioFiles)
            conditions = .normal
            calendar = SharedStorage.calendar(for: loaded.settings)
            clock = { Date() }
            store = fileStore
            let live = LiveVoiceServices.make() // LiveServices+Voice.swift
            recorder = live.recorder
            transcriber = live.transcriber
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
        voice = VoiceCapture()
        morningSession = MorningSession()
        eveningSession = EveningSession()
        onboardingDraft = OnboardingDraft()
        restoreRouting = RestoreRouting()
        historySelection = HistorySelection()
        system = SystemServices()
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
        let stamped = origin == .local ? LocalEdits.stamp(next, since: snapshot, at: now, device: deviceIdentity) : next
        // Held exactly as the store file and every other device read it (dates in whole seconds): sync
        // compares these dates with decoded ones, and an evening entry's `createdAt` is its identity (E5).
        let next = JSONFileStore.asStored(stamped)
        guard next != snapshot else { return }
        snapshot = next
        save(origin: origin)
    }

    private func save(origin: SnapshotOrigin) {
        writeToStore()
        if origin != .remote { effects.didChangeLocally() }
        effects.reloadWidgets()
        AudioTombstoneLog.shared.noteReferenced(snapshot.referencedAudioFiles)
    }

    /// Write the snapshot as one coordinated read-modify-write (`Store.update`): a widget change that
    /// landed since the last write is taken in inside the same step, so the app's save never overwrites
    /// it and the widget can't write in between. An unreadable file (copied aside at launch) is replaced.
    /// A failure is remembered (`saveFailed`), never swallowed.
    private func writeToStore() {
        let takeWidgetChanges = !saveFailed
        let lastSaved = lastSavedAt
        let memory = snapshot
        do {
            let written = try store.update(replacingUnreadable: true) { stored, storedModifiedAt in
                var next = memory
                if takeWidgetChanges,
                   StoreReload.shouldRead(fileModifiedAt: storedModifiedAt, lastSavedAt: lastSaved, saveFailed: false) {
                    next = next.takingWidgetChanges(from: stored)
                }
                stored = next
            }
            if written.snapshot != snapshot { snapshot = written.snapshot }
            lastSavedAt = written.modifiedAt
            if saveFailed { saveFailed = false }
        } catch {
            if !saveFailed { saveFailed = true }
        }
    }

    /// Becoming active: retry a failed save, or take in what the widget changed in the shared file since
    /// this app last wrote it. Only a step completed or undone there is taken; a file this app didn't
    /// manage to write is never adopted (it would read as notes and steps deleted here).
    func reloadFromStore() {
        if saveFailed {
            writeToStore()
            if !saveFailed { effects.reloadWidgets() }
            return
        }
        guard StoreReload.shouldRead(fileModifiedAt: store.modifiedAt, lastSavedAt: lastSavedAt, saveFailed: saveFailed),
              let stored = try? store.load() else { return }
        lastSavedAt = store.modifiedAt
        let next = snapshot.takingWidgetChanges(from: stored)
        // A local change (made on this phone), so it syncs and the widget reloads like any other.
        if next != snapshot { commit(next) }
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

    /// Synced settings travel to the user's other devices; `Settings.DeviceLocal` fields (reminders switch,
    /// input, time-zone pin) stay on this one (`SyncApply`).
    func updateSettings(_ body: (inout Settings) -> Void) {
        mutate { body(&$0.settings) }
        calendar = SharedStorage.calendar(for: snapshot.settings)
        if let fixed = fixture?.calendar ?? (launch.tapThrough ? Fixtures.calendar : nil) {
            // Fixtures and the tap-through keep their deterministic locale (en_GB) and, unless pinned, zone.
            calendar.locale = fixed.locale
            calendar.firstWeekday = fixed.firstWeekday
            if snapshot.settings.timeZoneID == nil { calendar.timeZone = fixed.timeZone }
        }
    }

    /// Clear the snapshot here (H2 on this device, or a wipe from another device). The store file is
    /// removed, A1's backup check starts over and the widget reloads. Sync is told separately (`LiveSync.wipeEverywhere`), never as
    /// an ordinary local change, so an empty snapshot is not pushed over the wipe marker.
    func deleteEverything() {
        snapshot = .empty
        // A1 must not offer the backup that was just deleted (N4): it looks again.
        restoreRouting.reset()
        if let fileStore = store as? JSONFileStore { try? fileStore.deleteAll() } else { try? store.save(.empty) }
        saveFailed = false
        lastSavedAt = store.modifiedAt
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
