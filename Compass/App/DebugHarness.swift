import SwiftUI
import CompassCore

/// What an `AppModel` runs on when the launch harness (`-screen`, `-tapthrough`) replaces the live
/// store and services. Built by `LaunchHarness.setup(for:)`, which is Debug only; Release never has one.
struct HarnessSetup {
    var fixture: ScreenFixture?
    var snapshot: CompassSnapshot
    var conditions: SystemConditions
    var calendar: Calendar
    var clock: () -> Date
    /// The tap-through clock's setter (`-tapthrough` only).
    var moveClock: ((Date) -> Void)?
    var store: Store
    var recorder: AudioRecorder
    var transcriber: SpeechTranscriber
    var cloud: CloudAssist
    var path: [ScreenID]
}

#if DEBUG
/// The fixture and fake wiring behind `-screen` and `-tapthrough`. Debug only: a Release build has no
/// `LaunchHarness`, so a shipped app always opens on the live store (CI checks the Release binary).
@MainActor
enum LaunchHarness {
    static func setup(for launch: LaunchOptions) -> HarnessSetup? {
        if launch.tapThrough {
            // UI tap-through (`-tapthrough`): the live flow from A1 on an empty in-memory store, with the
            // fakes, the fixtures' calendar and a clock the test moves (`advanceTapThroughClock`). No
            // fixture, so every screen behaves as on a phone; nothing touches iCloud, the store file,
            // permissions or notifications.
            let movable = MovableClock(Fixtures.date(Fixtures.todayKey, 8))
            return HarnessSetup(
                fixture: nil, snapshot: .empty, conditions: .normal, calendar: Fixtures.calendar,
                clock: { movable.now }, moveClock: { movable.now = $0 },
                store: InMemoryStore(.empty), recorder: FakeAudioRecorder(), transcriber: FakeSpeechTranscriber(),
                cloud: FakeCloudAssist(isEnabled: true), path: [.a1])
        }
        guard let id = launch.screen else { return nil }
        var f = Fixtures.fixture(for: id)
        if launch.variant == .remindersOff {
            f.conditions.notifications = .denied
            f.snapshot.settings.notificationsEnabled = false
        }
        let fixedNow = f.now
        return HarnessSetup(
            fixture: f, snapshot: f.snapshot, conditions: f.conditions, calendar: f.calendar,
            clock: { fixedNow }, moveClock: nil,
            store: InMemoryStore(f.snapshot),
            recorder: FakeAudioRecorder(permission: f.conditions.microphone, storageFull: f.conditions.storageFull),
            transcriber: FakeSpeechTranscriber(permission: f.conditions.speech, fails: f.conditions.transcriptionFails),
            cloud: FakeCloudAssist(isEnabled: f.snapshot.settings.cloudAssist, isOnline: f.conditions.online),
            path: [id])
    }

    /// After the model is built: the parts of a `-variant` that live in session state.
    static func prepare(_ model: AppModel) {
        if model.launch.variant == .restoreChoice {
            model.restoreRouting.foundSummary = BackupSummary(snapshot: Fixtures.restorableSnapshot)
            model.restoreRouting.choosing = true
        }
    }
}

/// A clock the tap-through UI test moves (`AppModel.advanceTapThroughClock`).
final class MovableClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

extension AppModel {
    /// `-tapthrough` only: move the clock to `hour:minute` today and judge the screen, as the boundary
    /// timer would on a phone.
    func advanceTapThroughClock(hour: Int, minute: Int) {
        guard let moveHarnessClock else { return }
        if entryCheckedAt == nil { entryCheckedAt = now }
        moveHarnessClock(todayKey.date(in: calendar, hour: hour, minute: minute))
        refreshEntryForClock()
    }
}

/// `-tapthrough` only: a small control on the left edge (clear of the status bar and the nav row) the UI
/// test taps to move the clock to 21:05, so the evening comes in the way the boundary timer brings it on
/// a phone. Its value counts the taps, so a failing test can tell a missed tap from a screen that stayed.
struct TapThroughClockControl: View {
    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            model.advanceTapThroughClock(hour: 21, minute: 5)
        } label: {
            Color.white.opacity(0.05).frame(width: 24, height: 24)
        }
        .accessibilityLabel("Move the clock to the evening")
        .accessibilityValue("\(taps)")
        .accessibilityIdentifier("tapthrough-evening")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
#endif
