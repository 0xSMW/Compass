import Foundation

/// Conditions outside the data: permissions, storage, network, time zone. Drives I-flow states.
public struct SystemConditions: Hashable, Sendable {
    public var microphone: PermissionState
    public var speech: PermissionState
    public var notifications: PermissionState
    public var storageFull: Bool
    public var online: Bool
    public var transcriptionFails: Bool
    /// I3: the time zone the rhythm followed before the device moved ("Asia/Bangkok").
    public var previousTimeZoneID: String?
    /// R1/R2: something to restore from iCloud. R3: false.
    public var iCloudBackupAvailable: Bool

    public init(
        microphone: PermissionState = .granted,
        speech: PermissionState = .granted,
        notifications: PermissionState = .granted,
        storageFull: Bool = false,
        online: Bool = true,
        transcriptionFails: Bool = false,
        previousTimeZoneID: String? = nil,
        iCloudBackupAvailable: Bool = true
    ) {
        self.microphone = microphone
        self.speech = speech
        self.notifications = notifications
        self.storageFull = storageFull
        self.online = online
        self.transcriptionFails = transcriptionFails
        self.previousTimeZoneID = previousTimeZoneID
        self.iCloudBackupAvailable = iCloudBackupAvailable
    }

    public static let normal = SystemConditions()
}

/// Everything a screen needs to render its board state: clock, data, conditions.
/// Transient UI (keyboard up, sheet open, recording in progress, transcript expanded) is
/// drawn by the flow's view for that ScreenID, not stored here.
public struct ScreenFixture: Sendable {
    public var id: ScreenID
    public var now: Date
    public var calendar: Calendar
    public var snapshot: CompassSnapshot
    public var conditions: SystemConditions
    /// Live words for listening states (A3, B2, C5, D3, D3L, D4), settled + pending.
    public var transcript: TranscriptUpdate?
    /// E2/E4/E5/E6: the History day that is open.
    public var selectedDay: DayKey?

    public var largestText: Bool { id.isLargestText }
    public var todayKey: DayKey { DayKey(now, calendar: calendar) }
    public var today: Day? { snapshot.day(todayKey) }
}

/// Copy and data taken from the v3 boards. Deterministic: fixed ids, fixed dates.
public enum Fixtures {
    // MARK: Clock

    public static let timeZone = TimeZone(identifier: "Europe/London")!

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = 2
        return c
    }

    /// Tuesday 10 November 2026 ("Tuesday 10 November" in I5, "4–10 Nov" in E3).
    public static let todayKey = DayKey(year: 2026, month: 11, day: 10)

    public static func date(_ key: DayKey = todayKey, _ hour: Int, _ minute: Int = 0, calendar: Calendar = Fixtures.calendar) -> Date {
        key.date(in: calendar, hour: hour, minute: minute)
    }

    /// 10 Nov 2026 14:00 London.
    public static var referenceDate: Date { date(todayKey, 14) }

    // MARK: Copy

    public static let goalText = "Earn my first million, stay strong, keep close friends."
    public static let shortGoalText = "Run a marathon."
    public static let longGoalText = "Build a calm, profitable studio, stay strong for my kids, keep close friends."
    public static let vagueGoalText = "Be happier."
    public static let intentionText = "Patient. Ship one thing."
    public static let stepTitle = "Text Sam about Friday dinner"
    public static let longStepTitle = "Draft the pricing section of the Ridgeline proposal, check the numbers with Priya, and send it to Lena"
    public static let pitchStepTitle = "Pitch Ridgeline"
    public static let workStepTitle = "Call Lena about the pilot"
    public static let afternoonStepTitle = "Reply to Lena’s email"
    public static let smallerStepTitle = "Open the Ridgeline doc for two minutes"
    public static let noteText = "Sam is free Friday after 7"
    public static let reflectionTranscript = "Texted Sam. Friday is on, his place, and Priya is coming."
    public static let reflectionSummary = "Texted Sam. Friday dinner is on."
    public static let longReflectionTranscript = "Texted Sam. Friday is on, his place, and Priya is coming. She’s moving to Lisbon in March, so this might be one of the last easy ones. I want to book a weekend there before she goes, maybe the second week of February, and tell her on Friday. Also need to remember the wine she liked last time."
    public static let longReflectionSummary = "Texted Sam. Dinner Friday; plan a Lisbon weekend."
    public static let notTodayTranscript = "Sick. Slept most of the day"
    public static let morningSpeech = "Patient. Calm with the team. Ship one thing"
    public static let whyText = "So the people I love never have to worry about money."

    public static let summaries: [String: String] = [
        reflectionTranscript: reflectionSummary,
        longReflectionTranscript: longReflectionSummary,
    ]

    // MARK: Ids

    private static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    public static let goalID = uuid(1)
    public static let wealthPartID = uuid(11)
    public static let strengthPartID = uuid(12)
    public static let friendsPartID = uuid(13)

    public static let parts: [GoalPart] = [
        GoalPart(id: wealthPartID, title: "Earn my first million", symbol: .wealth),
        GoalPart(id: strengthPartID, title: "Stay strong", symbol: .strength),
        GoalPart(id: friendsPartID, title: "Keep close friends", symbol: .friends),
    ]

    public static var friendsPart: GoalPart { parts[2] }

    /// Goal started 14 Apr 2026 ("Since 14 Apr · 212 steps").
    public static var goal: Goal {
        Goal(id: goalID, text: goalText, parts: parts, createdAt: date(DayKey(year: 2026, month: 4, day: 14), 8),
             why: Note(id: uuid(2), text: whyText, duration: 9, createdAt: date(DayKey(year: 2026, month: 4, day: 16), 7, 20)),
             whyAsked: true)
    }

    public static var intention: Intention { Intention(text: intentionText, duration: 4, createdAt: date(todayKey, 7, 12)) }

    public static var step: Step {
        Step(id: uuid(100), title: stepTitle, partID: friendsPartID, createdAt: date(todayKey, 7, 14), source: .suggested)
    }

    public static var note: Note {
        Note(id: uuid(200), text: noteText, duration: 12, createdAt: date(todayKey, 12, 40), device: "This iPhone")
    }

    public static var settings: Settings { Settings() }

    // MARK: History

    /// The last seven days from history.html (oldest first). nil text = moved without words.
    private static let lastWeek: [(String, Bool, UUID?)] = [
        ("Drafted the pricing page", true, wealthPartID),
        ("Ran 5 km", true, strengthPartID),
        ("Sick. Rested.", false, nil),
        ("Dinner with Sam and Priya", true, friendsPartID),
        ("Long walk, no phone", true, strengthPartID),
        ("Pitched Ridgeline", true, wealthPartID),
    ]

    /// Week patterns from history.html, oldest first (each string oldest → newest day).
    private static let weekPatterns = ["1111111", "1110111", "1111110", "1100000", "0000000", "0000011", "1011101", "1111011"]

    private static let filler: [(String, UUID)] = [
        ("Ran 5 km", strengthPartID), ("Called Mum", friendsPartID), ("Sent two proposals", wealthPartID),
        ("Gym, legs", strengthPartID), ("Lunch with Priya", friendsPartID), ("Fixed the invoice flow", wealthPartID),
    ]

    /// Past days for the standard goal: 14 Apr → 9 Nov, patterned like the boards.
    public static func historyDays(calendar: Calendar = Fixtures.calendar) -> [Day] {
        let start = DayKey(year: 2026, month: 4, day: 14)
        let yesterday = todayKey.adding(days: -1, calendar: calendar)
        let lastWeekStart = todayKey.adding(days: -6, calendar: calendar)
        let patternStart = lastWeekStart.adding(days: -7 * weekPatterns.count, calendar: calendar)
        var days: [Day] = []
        var key = start
        var i = 0
        while key <= yesterday {
            let moved: Bool
            var title = filler[i % filler.count].0
            var part: UUID? = filler[i % filler.count].1
            var reason: String?
            if key >= lastWeekStart {
                let entry = lastWeek[patternStart.days(to: key, calendar: calendar) - 7 * weekPatterns.count]
                (title, moved, part) = (entry.0, entry.1, entry.2)
                if !moved { reason = entry.0 }
            } else if key >= patternStart {
                let offset = patternStart.days(to: key, calendar: calendar)
                let pattern = Array(weekPatterns[offset / 7])
                moved = pattern[offset % 7] == "1"
                if !moved { reason = "Busy." }
            } else {
                moved = i % 7 != 5
                if !moved { reason = "Travelling." }
            }
            if key == start { title = "Opened a savings account"; part = wealthPartID }
            if key == yesterday { title = "Pitched Ridgeline" }
            var day = Day(key: key, goalID: goalID)
            let at = { (h: Int, m: Int) in date(key, h, m, calendar: calendar) }
            if moved {
                let stepName = key == yesterday ? pitchStepTitle : title
                day.step = Step(id: uuid(10_000 + i), title: stepName, partID: part, createdAt: at(7, 10), completedAt: at(17, 30))
                day.reflection = Reflection(outcome: .moved, transcript: title, summary: title, duration: 10, partID: part, createdAt: at(21, 10))
            } else if let reason, key >= patternStart.adding(days: -14, calendar: calendar) {
                // Recent missed days carry their reason; quiet weeks (7–13 Oct) stay empty.
                if !(key >= patternStart && key < lastWeekStart && weekPatterns[patternStart.days(to: key, calendar: calendar) / 7] == "0000000") {
                    day.reflection = Reflection(outcome: .notToday, transcript: reason, summary: reason, duration: 6, createdAt: at(21, 5))
                }
            }
            if key == DayKey(year: 2026, month: 11, day: 7) {
                day.intention = Intention(text: "Show up for people.", createdAt: at(7, 5))
                day.reflection = Reflection(
                    outcome: .moved,
                    transcript: "Cooked at Sam’s. Priya’s moving to Lisbon in March, so we picked a weekend to visit before then. First night in a month I didn’t look at my phone. Want to make this monthly, not whenever.",
                    summary: "Cooked at Sam’s. Lisbon trip before March.",
                    duration: 48, partID: friendsPartID, createdAt: at(21, 30), device: "iPad")
            }
            if day.step != nil || day.reflection != nil { days.append(day) }
            key = key.adding(days: 1, calendar: calendar)
            i += 1
        }
        return days
    }

    /// The standard snapshot: goal, history up to yesterday, `today` as given.
    public static func snapshot(today: Day?, goal: Goal = Fixtures.goal, settings: Settings = Fixtures.settings, history: [Day]? = nil) -> CompassSnapshot {
        var days = history ?? historyDays()
        if let today { days.append(today) }
        return CompassSnapshot(goal: goal, pastGoals: pastGoals, days: days, settings: settings)
    }

    public static var pastGoals: [Goal] {
        [
            Goal(id: uuid(3), text: "Run a half marathon.", parts: [GoalPart(id: uuid(31), title: "Run a half marathon", symbol: .strength)],
                 createdAt: date(DayKey(year: 2026, month: 1, day: 5), 8), status: .achieved, endedAt: date(DayKey(year: 2026, month: 4, day: 12), 10)),
            Goal(id: uuid(4), text: "Write every morning.", parts: [GoalPart(id: uuid(41), title: "Write every morning", symbol: .sun)],
                 createdAt: date(DayKey(year: 2025, month: 9, day: 1), 8), status: .replaced, endedAt: date(DayKey(year: 2025, month: 12, day: 20), 10)),
        ]
    }

    // MARK: Today variants

    public static func today(intention: Bool = true, step: Step? = Fixtures.step, done: Bool = false, notes: [Note] = [Fixtures.note],
                             reflection: Reflection? = nil, morningSkipped: Bool = false) -> Day {
        var s = step
        if done { s?.completedAt = date(todayKey, 14) }
        return Day(key: todayKey, goalID: goalID, intention: intention ? Fixtures.intention : nil, step: s, notes: notes,
                   reflection: reflection, morningSkipped: morningSkipped)
    }

    public static var savedReflection: Reflection {
        Reflection(outcome: .moved, transcript: reflectionTranscript, summary: reflectionSummary, duration: 14, partID: friendsPartID, createdAt: date(todayKey, 21, 20))
    }

    // MARK: Per-screen fixtures

    public static func fixture(for id: ScreenID) -> ScreenFixture {
        let cal = calendar
        var now = date(todayKey, 14)
        var snap = snapshot(today: today())
        var cond = SystemConditions.normal
        var transcript: TranscriptUpdate?
        var selected: DayKey?

        func onboarding(_ hour: Int = 8) {
            now = date(todayKey, hour)
            snap = CompassSnapshot(settings: Settings())
        }
        func morning(_ hour: Int = 7, _ minute: Int = 30, intention: Bool = false) {
            now = date(todayKey, hour, minute)
            snap = snapshot(today: intention ? Day(key: todayKey, goalID: goalID, intention: Fixtures.intention) : nil)
        }
        func firstWeek(goalDay: Int) -> Goal {
            var g = goal
            g.createdAt = date(todayKey.adding(days: -(goalDay - 1), calendar: cal), 8)
            g.why = nil
            g.whyAsked = false
            return g
        }
        func evening(_ day: Day, hour: Int = 21, minute: Int = 30) {
            now = date(todayKey, hour, minute)
            snap = snapshot(today: day)
        }

        switch id {
        // A · Onboarding
        case .a1, .a2, .a4, .a4k, .a5, .a7, .r1, .r2, .a8: onboarding()
        case .a3: onboarding(); transcript = TranscriptUpdate(settled: "Earn my first million, stay strong, keep close", pending: "friends")
        case .a4b: onboarding()
        case .a6: onboarding(); cond.notifications = .notDetermined
        case .r3: onboarding(); cond.iCloudBackupAvailable = false

        // B · Morning
        case .b1, .b8: morning()
        case .b2: morning(); transcript = TranscriptUpdate(settled: "Patient. Calm with the team. Ship one", pending: "thing")
        case .b3: morning(7, 34, intention: true)
        case .b4, .b5:
            now = date(todayKey, 7, 34)
            let g = firstWeek(goalDay: 2)
            snap = CompassSnapshot(goal: g, days: [Day(key: todayKey, goalID: goalID, intention: intention)], settings: settings)
        case .b6: morning(14, 10)
        case .b7:
            now = date(todayKey, 7, 30)
            snap = CompassSnapshot(goal: firstWeek(goalDay: 3), days: [], settings: settings)

        // C · Today
        case .c1: now = date(todayKey, 10); snap = snapshot(today: today(intention: false, step: nil, notes: [], morningSkipped: true))
        case .c2: now = date(todayKey, 13); snap = snapshot(today: today(step: nil, notes: []))
        case .c3, .c6, .c10, .c11, .c11b: break
        case .c5: transcript = TranscriptUpdate(settled: "Sam is free Friday after", pending: "seven")
        case .c4: snap = snapshot(today: today(done: true))
        case .c7:
            var g = goal
            g.text = shortGoalText
            g.parts = [GoalPart(id: strengthPartID, title: "Run a marathon", symbol: .strength)]
            var d = today(step: Step(id: uuid(101), title: "Run 5 km", partID: strengthPartID, createdAt: date(todayKey, 7, 10)), notes: [])
            d.intention = Intention(text: "Easy miles.", createdAt: date(todayKey, 7, 5))
            snap = snapshot(today: d, goal: g)
        case .c8:
            var g = goal
            g.text = longGoalText
            g.parts = [
                GoalPart(id: wealthPartID, title: "Build a calm, profitable studio", symbol: .wealth),
                GoalPart(id: strengthPartID, title: "Stay strong for my kids", symbol: .strength),
                GoalPart(id: friendsPartID, title: "Keep close friends", symbol: .friends),
            ]
            // Three notes today; the row shows the latest and "3 notes".
            var d = today(step: Step(id: uuid(106), title: "Send Lena the pilot price", partID: wealthPartID, createdAt: date(todayKey, 7, 10)),
                          notes: [
                            Note(id: uuid(202), text: "Lena wants numbers by Thursday", duration: 7, createdAt: date(todayKey, 9, 10), device: "This iPhone"),
                            Note(id: uuid(203), text: "Pilot is 40 seats", createdAt: date(todayKey, 10, 30), device: "This iPhone"),
                            Note(id: uuid(204), text: "Lena: price the pilot per seat", duration: 9, createdAt: date(todayKey, 11), device: "This iPhone"),
                          ])
            d.intention = Intention(text: "Finish one thing properly.", createdAt: date(todayKey, 7, 5))
            snap = snapshot(today: d, goal: g)
        case .c9:
            let s = Step(id: uuid(102), title: "Draft the pricing section of the Ridgeline proposal and send it to Lena", partID: wealthPartID, createdAt: date(todayKey, 7, 10))
            snap = snapshot(today: today(step: s, notes: [Note(id: uuid(201), text: "Needed before Thursday’s board meeting", duration: 21, createdAt: date(todayKey, 11))]))

        // D · Evening
        case .d1, .d3, .d3L, .d4, .d7:
            evening(today())
            switch id {
            case .d3: transcript = TranscriptUpdate(settled: "Texted Sam. Friday is on, his place, and Priya is", pending: "coming")
            case .d3L: transcript = TranscriptUpdate(settled: String(longReflectionTranscript.dropLast(1)), pending: "")
            case .d4: transcript = TranscriptUpdate(settled: "Sick. Slept most of the", pending: "day")
            default: break
            }
        case .d1L:
            evening(today(step: Step(id: uuid(103), title: longStepTitle, partID: wealthPartID, createdAt: date(todayKey, 7, 10))))
        case .d2: evening(today(step: nil))
        case .d2b: evening(today(done: true))
        case .d5, .d8: evening(today(done: true, reflection: savedReflection), minute: 32)
        case .d5L:
            var r = savedReflection
            r.transcript = longReflectionTranscript
            r.summary = longReflectionSummary
            r.duration = 48
            evening(today(done: true, reflection: r), minute: 34)
        case .d6:
            var r = savedReflection
            r.summary = nil
            r.transcript = ""
            r.summaryState = .waitingForNetwork
            evening(today(done: true, reflection: r), minute: 32)
            cond.online = false
        case .d6b:
            var r = savedReflection
            r.summary = nil
            r.transcript = ""
            r.summaryState = .transcriptionFailed
            evening(today(done: true, reflection: r), minute: 32)
            cond.transcriptionFails = true

        // E · History
        case .e1, .e3: evening(today(done: true, reflection: savedReflection), hour: 21, minute: 40)
        case .e2, .e4, .e6:
            evening(today(done: true, reflection: savedReflection), hour: 21, minute: 40)
            selected = DayKey(year: 2026, month: 11, day: 7)
        case .e5:
            evening(today(done: true, reflection: savedReflection), hour: 21, minute: 40)
            let sat = DayKey(year: 2026, month: 11, day: 7)
            selected = sat
            snap.updateDay(sat) { day in
                day.mergeCandidates = [
                    Reflection(outcome: .moved, transcript: "Dinner with Sam and Priya.", summary: "Dinner with Sam and Priya.", duration: 21,
                               partID: friendsPartID, createdAt: date(sat, 21, 14), device: "This iPhone"),
                ]
            }

        // F · Lapse and return
        case .f1:
            now = date(todayKey, 7, 40)
            // Two quiet days (8–9 Nov). The work part had no moved day in the week before, so the
            // smaller idea goes to it (F1 shows the wealth symbol with the Ridgeline step).
            let history = historyDays().filter { $0.key <= todayKey.adding(days: -3, calendar: cal) }
                .filter { !($0.key >= todayKey.adding(days: -7, calendar: cal) && ($0.step?.partID ?? $0.reflection?.partID) == wealthPartID) }
            snap = snapshot(today: Day(key: todayKey, goalID: goalID, intention: Intention(text: "Just start.", createdAt: date(todayKey, 7, 36))), history: history)
        case .f2:
            now = date(todayKey, 8)
            let last = todayKey.adding(days: -9, calendar: cal)
            // return.html: 41 steps toward this goal, the last one 9 days ago.
            var history = Array(historyDays().filter { $0.key < last && $0.moved }.suffix(40))
            var lastDay = Day(key: last, goalID: goalID)
            lastDay.step = Step(id: uuid(104), title: pitchStepTitle, partID: wealthPartID, createdAt: date(last, 7), completedAt: date(last, 16))
            lastDay.reflection = Reflection(outcome: .moved, transcript: "Pitched Ridgeline", summary: "Pitched Ridgeline", duration: 8, partID: wealthPartID, createdAt: date(last, 21))
            history.append(lastDay)
            snap = snapshot(today: nil, history: history)
        case .f3:
            now = date(todayKey, 8)
            let last = todayKey.adding(days: -34, calendar: cal)
            var g = goal
            g.createdAt = date(last.adding(days: -60, calendar: cal), 8)
            let history = (0..<41).map { n -> Day in
                let k = last.adding(days: -n, calendar: cal)
                let f = filler[n % filler.count]
                return Day(key: k, goalID: goalID, step: Step(id: uuid(20_000 + n), title: f.0, partID: f.1, createdAt: date(k, 7), completedAt: date(k, 17)))
            }
            snap = snapshot(today: nil, goal: g, history: history)

        // G · Goal
        case .g1, .g3: break
        case .g2:
            var g = goal
            g.status = .achieved
            g.endedAt = date(todayKey, 21, 40)
            var d = today(step: Step(id: uuid(105), title: "Signed Ridgeline", partID: wealthPartID, createdAt: date(todayKey, 7)), done: true)
            d.reflection = Reflection(outcome: .moved, transcript: "Signed Ridgeline", summary: "Signed Ridgeline", duration: 12, partID: wealthPartID, createdAt: date(todayKey, 21, 30))
            now = date(todayKey, 21, 40)
            snap = snapshot(today: d, goal: g)

        // H · Settings
        case .h1, .h2: break

        // I · System
        case .i1: morning(); cond.microphone = .denied
        case .i2: cond.notifications = .denied; var s = snap.settings; s.notificationsEnabled = false; snap.settings = s
        case .i3:
            cond.previousTimeZoneID = "Asia/Bangkok"
            var s = snap.settings; s.timeZoneID = "Asia/Tokyo"; snap.settings = s
        case .i4: evening(today()); cond.storageFull = true
        case .i5: now = date(todayKey, 7); snap = snapshot(today: nil)
        case .i6: break
        }

        var fixtureCalendar = cal
        if id == .i3 { fixtureCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")! }
        return ScreenFixture(id: id, now: now, calendar: fixtureCalendar, snapshot: snap, conditions: cond, transcript: transcript, selectedDay: selected)
    }
}
