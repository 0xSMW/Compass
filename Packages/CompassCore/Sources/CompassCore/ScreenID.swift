import Foundation

/// The nine flows on the v3 map.
public enum Flow: String, CaseIterable, Hashable, Sendable {
    case onboarding = "A"
    case morning = "B"
    case today = "C"
    case evening = "D"
    case history = "E"
    case lapse = "F"
    case goal = "G"
    case settings = "H"
    case system = "I"

    public var title: String {
        switch self {
        case .onboarding: "Onboarding"
        case .morning: "Morning"
        case .today: "Today"
        case .evening: "Evening"
        case .history: "History"
        case .lapse: "Lapse and return"
        case .goal: "Goal changes"
        case .settings: "Settings"
        case .system: "System"
        }
    }

    /// Board file stem in design/compass-v3/renders/screens (e.g. "V3Today").
    public var boardStem: String {
        switch self {
        case .onboarding: "V3Onboarding"
        case .morning: "V3Morning"
        case .today: "V3Today"
        case .evening: "V3Evening"
        case .history: "V3History"
        case .lapse: "V3Return"
        case .goal: "V3Goal"
        case .settings: "V3Settings"
        case .system: "V3System"
        }
    }

    public var screens: [ScreenID] { ScreenID.allCases.filter { $0.flow == self } }
}

/// Every one of the 66 screen states drawn on the v3 boards, in board order.
/// Raw values are the IDs printed on the boards ("C11b", "D1L"). Pass one with `-screen <ID>`.
public enum ScreenID: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    // A · Onboarding (onboarding.html)
    case a1 = "A1", a2 = "A2", a3 = "A3", a4 = "A4", a4k = "A4k", a4b = "A4b", a5 = "A5", a6 = "A6", a7 = "A7"
    case r1 = "R1", r2 = "R2", r3 = "R3", a8 = "A8"
    // B · Morning (morning.html)
    case b1 = "B1", b2 = "B2", b3 = "B3", b4 = "B4", b5 = "B5", b6 = "B6", b7 = "B7", b8 = "B8"
    // C · Today (today.html)
    case c1 = "C1", c2 = "C2", c3 = "C3", c4 = "C4", c5 = "C5", c6 = "C6", c7 = "C7", c8 = "C8", c9 = "C9", c10 = "C10"
    case c11 = "C11", c11b = "C11b"
    // D · Evening (evening.html)
    case d1 = "D1", d1L = "D1L", d2 = "D2", d2b = "D2b", d3 = "D3", d3L = "D3L", d4 = "D4", d5 = "D5", d5L = "D5L"
    case d6 = "D6", d6b = "D6b", d7 = "D7", d8 = "D8"
    // E · History (history.html)
    case e1 = "E1", e2 = "E2", e3 = "E3", e4 = "E4", e5 = "E5", e6 = "E6"
    // F · Lapse and return (return.html)
    case f1 = "F1", f2 = "F2", f3 = "F3"
    // G · Goal changes (goal.html)
    case g1 = "G1", g2 = "G2", g3 = "G3"
    // H · Settings (settings.html)
    case h1 = "H1", h2 = "H2"
    // I · System (system.html)
    case i1 = "I1", i2 = "I2", i3 = "I3", i4 = "I4", i5 = "I5", i6 = "I6"

    public var id: String { rawValue }

    public var flow: Flow {
        switch self {
        case .a1, .a2, .a3, .a4, .a4k, .a4b, .a5, .a6, .a7, .r1, .r2, .r3, .a8: .onboarding
        case .b1, .b2, .b3, .b4, .b5, .b6, .b7, .b8: .morning
        case .c1, .c2, .c3, .c4, .c5, .c6, .c7, .c8, .c9, .c10, .c11, .c11b: .today
        case .d1, .d1L, .d2, .d2b, .d3, .d3L, .d4, .d5, .d5L, .d6, .d6b, .d7, .d8: .evening
        case .e1, .e2, .e3, .e4, .e5, .e6: .history
        case .f1, .f2, .f3: .lapse
        case .g1, .g2, .g3: .goal
        case .h1, .h2: .settings
        case .i1, .i2, .i3, .i4, .i5, .i6: .system
        }
    }

    /// Board caption title, e.g. "Just completed" (board shows "C4 · Just completed").
    public var title: String { Self.captions[self]!.0 }

    /// Board caption subtitle, e.g. "Circle fills, one click. Undo sits where you tapped, for 5 s."
    public var caption: String { Self.captions[self]!.1 }

    /// "C4 · Just completed"
    public var label: String { "\(rawValue) · \(title)" }

    /// States drawn at the largest accessibility text size (AX5). Launch with Dynamic Type AX5.
    public var isLargestText: Bool {
        switch self {
        case .a8, .b8, .c11, .c11b, .d7, .d8, .e6: true
        default: false
        }
    }

    /// 1-based position on its board, matching renders/screens/<stem>-NN.png.
    public var boardIndex: Int { flow.screens.firstIndex(of: self)! + 1 }

    /// Design render file name, e.g. "V3Today-04.png" for C4.
    public var designRender: String { String(format: "%@-%02d.png", flow.boardStem, boardIndex) }

    /// Next screen in board order (used by stubs to walk a flow).
    public var next: ScreenID? {
        let all = Self.allCases
        let i = all.firstIndex(of: self)!
        return i + 1 < all.count ? all[i + 1] : nil
    }

    public init?(argument: String) {
        if let s = ScreenID(rawValue: argument) { self = s; return }
        if let s = ScreenID.allCases.first(where: { $0.rawValue.lowercased() == argument.lowercased() }) { self = s; return }
        return nil
    }

    private static let captions: [ScreenID: (String, String)] = [
        .a1: ("Welcome", "One promise, one button. Restore if you’re back."),
        .a2: ("Goal", "Say it or type it"),
        .a3: ("Listening", "The question greys; words land under it; stops on silence"),
        .a4: ("Review", "Your words become the goal; tap to edit, or say it again"),
        .a4k: ("Review, editing", "Keyboard up: the field stays at 128, Continue sits on the keyboard"),
        .a4b: ("Vague goal", "One question to make it concrete; never a block"),
        .a5: ("Parts", "Split and symbols proposed; tap a part to change it"),
        .a6: ("Rhythm and notifications", "Times and the permission in one step"),
        .a7: ("Privacy", "What stays on the phone; one switch for cloud help"),
        .r1: ("Restoring", "From Welcome. Shows what’s coming back."),
        .r2: ("Restored", "Your goal and total, then Today"),
        .r3: ("Nothing to restore", "Plain reason, two ways forward"),
        .a8: ("Largest text", "Title and hint wrap down; the voice dock stays on 712"),
        .b1: ("Center", "Read the goal. Say who you’ll be."),
        .b2: ("Speaking", "Goal becomes the subject; your words land under the question"),
        .b3: ("Plan, with a suggestion", "The quietest part of the goal gets the idea"),
        .b4: ("First week", "No history yet, so you name the step"),
        .b5: ("Typing a step", "Keyboard up: the field stays at 224, Add sits on the keyboard"),
        .b6: ("Opened after noon", "No centering; the goal is the subject, one step for what’s left"),
        .b7: ("Day 3: why it matters", "Moved out of onboarding; asked once, skippable"),
        .b8: ("Largest text: Center", "Goal wraps longer; the dock doesn’t scale or move"),
        .c1: ("Nothing planned", "Morning skipped. + opens planning (voice or typing)."),
        .c2: ("Intention, no step", "Allowed. Evening asks if you moved anyway."),
        .c3: ("Step open", "The everyday state, with today’s latest note"),
        .c4: ("Just completed", "Circle fills, one click. Undo sits where you tapped, for 5 s."),
        .c5: ("Recording a note", "Note row becomes the recorder; words appear where notes live"),
        .c6: ("Step options", "Tap ••• on the card: change, move to another part, delete"),
        .c7: ("Short content", "One-line goal and step: same anchors, more air"),
        .c8: ("Long goal", "Header grows down; nothing below it moves"),
        .c9: ("Long step", "Card grows upward; its bottom and control stay put"),
        .c10: ("Typing a note", "Keyboard covers the card; the field sits on the keyboard"),
        .c11: ("Largest text, at rest", "Goal starts at 128 below the nav, fully visible; the rest scrolls"),
        .c11b: ("Largest text, scrolled to end", "Last line clears the notes row by 24; nav turns solid"),
        .d1: ("Step still open", "Subject above, question at 224, two answers on 712"),
        .d1L: ("Long step", "Subject wraps to three lines; the question doesn’t move"),
        .d2: ("No step planned", "The goal is the subject; a yes asks what you did"),
        .d2b: ("Done earlier", "Already completed today, so only one question"),
        .d3: ("Reflect after Done", "The question greys; your words land under it"),
        .d3L: ("Long reflection", "Older lines scroll up under a fade; nothing below moves"),
        .d4: ("Reflect after Not today", "Same frame; the answer becomes that day’s reason"),
        .d5: ("Saved", "The summary takes the question’s place; the player takes the mic’s"),
        .d5L: ("Saved, transcript open", "The transcript scrolls in the middle; summary and player hold"),
        .d6: ("Saved offline", "Same slots: the summary waits, audio is safe"),
        .d6b: ("Text failed", "Retry, or type it; the recording stays either way"),
        .d7: ("Largest text: question", "Circles become full-width buttons; Done keeps the 712 line"),
        .d8: ("Largest text: saved", "Summary wraps, chips stack; player stays on 712"),
        .e1: ("This week", "What you did, for which part, and why days were missed"),
        .e2: ("A day", "Same frame as a saved evening entry"),
        .e3: ("Earlier weeks", "Each week opens as E1; empty weeks stay visible"),
        .e4: ("Edit a past day", "Summary, part, moved or not, delete. Save on the 712 line."),
        .e5: ("Two devices, same day", "Notes and audio merge; only the summary asks"),
        .e6: ("Largest text: a day", "Subject lines grow, so the summary starts lower; the player holds 712"),
        .f1: ("After 2 quiet days", "The normal plan frame (B3) with a smaller step"),
        .f2: ("After 3–29 quiet days", "What you’ve done, your own reason, one way back"),
        .f3: ("After 30+ quiet days", "Keep, revise or replace; history stays either way"),
        .g1: ("Your goal", "Edit wording or parts, or end it"),
        .g2: ("Achieved", "The end marker fills; first and last steps side by side"),
        .g3: ("Past goals", "Each keeps its full line and memos"),
        .h1: ("Settings", "Goal, times, input, privacy, data"),
        .h2: ("Delete everything", "Says exactly what goes; export first"),
        .i1: ("Microphone off", "Center keeps its text; the dock becomes Type instead"),
        .i2: ("Notifications off", "One notice in the notes row until dismissed"),
        .i3: ("New time zone", "The day follows you; the old times are one tap away"),
        .i4: ("Storage full", "Recording can’t start; typing takes the 712 line"),
        .i5: ("Notifications", "Morning shows the goal; evening shows the step"),
        .i6: ("Widgets", "Complete today’s step without opening the app"),
    ]
}

extension ScreenID {
    /// The screen the live app opens on for a phase (no fixture).
    public static func entry(for phase: DayPhase, today: Day?) -> ScreenID {
        switch phase {
        case .onboarding: return .a1
        case .morning(let plan):
            if !plan.startsWithCenter { return .b6 }
            if plan.asksWhy { return .b7 }
            return .b1
        case .today:
            guard let today else { return .c1 }
            if let step = today.step { return step.isDone ? .c4 : .c3 }
            return today.intention == nil ? .c1 : .c2
        case .evening(let kind):
            switch kind {
            case .stepOpen: return .d1
            case .noStep: return .d2
            case .doneEarlier: return .d2b
            }
        case .returning: return .f2
        case .checkGoal: return .f3
        }
    }
}
