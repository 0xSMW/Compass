import Foundation

// Rules for the morning (B) and evening (D) rituals: planning, live words, silence, and how a
// reflection is saved, summarised and shown. Pure and deterministic; the app's voice stack and
// views call these.

// MARK: - Live words

extension TranscriptUpdate {
    /// Splits a recogniser's running text into settled words and the trailing word still being
    /// recognised (drawn dim). A final result settles everything.
    public static func recognizing(_ text: String, isFinal: Bool) -> TranscriptUpdate {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        let joined = words.joined(separator: " ")
        if isFinal || words.count == 0 { return TranscriptUpdate(settled: joined, isFinal: isFinal) }
        return TranscriptUpdate(
            settled: words.dropLast().joined(separator: " "),
            pending: String(words[words.count - 1]),
            isFinal: false
        )
    }
}

// MARK: - Silence

/// "Stops on silence": once words have landed, a pause of `silence` seconds ends the recording.
/// Never stops before anything was said (except at `maxDuration`).
///
/// Voice is judged against the room, not a fixed level. The detector tracks the noise floor: it falls
/// quickly to quieter levels (the gaps between words) and climbs slowly, at `risePerSecond`, through
/// steady sound. A level counts as voice when it is `margin` above that floor (and at least
/// `threshold`, at most `ceiling`). Levels use the recorder's 0...1 scale (-50…-5 dBFS, 0.1 ≈ 4.5 dB):
/// the default margin 0.15 is about 7 dB. In a silent room the bar is `threshold`-ish; in a café the bar
/// rises with the hum within a few seconds, so a pause still ends the take.
public struct SilenceDetector: Hashable, Sendable {
    /// Lowest level that ever counts as voice (a silent room).
    public var threshold: Float
    /// How far above the noise floor a level must be to count as voice.
    public var margin: Float
    /// Highest bar for voice, however loud the room. Words from the recogniser always count as voice.
    public var ceiling: Float
    /// How fast the floor can climb through steady sound (level units per second).
    public var risePerSecond: Float
    /// Seconds of quiet after speech that end the recording.
    public var silence: TimeInterval
    /// Hard limit for one recording.
    public var maxDuration: TimeInterval

    public private(set) var startedAt: TimeInterval?
    public private(set) var lastVoiceAt: TimeInterval?
    /// Estimated level of the room without speech. Starts as a silent room.
    public private(set) var noiseFloor: Float = 0
    private var lastSampleAt: TimeInterval?

    /// Share of the gap closed per sample when the level drops below the floor.
    static let fallRate: Float = 0.5

    public init(threshold: Float = 0.12, margin: Float = 0.15, ceiling: Float = 0.8, risePerSecond: Float = 0.05,
                silence: TimeInterval = 2.5, maxDuration: TimeInterval = 300) {
        self.threshold = threshold
        self.margin = margin
        self.ceiling = ceiling
        self.risePerSecond = risePerSecond
        self.silence = silence
        self.maxDuration = maxDuration
    }

    /// The level that counts as voice right now.
    public var voiceThreshold: Float { min(ceiling, max(threshold, noiseFloor + margin)) }

    public func isVoice(_ level: Float) -> Bool { level >= voiceThreshold }

    /// Feed one input level sampled at `t` (seconds, any monotonic clock).
    public mutating func feed(level: Float, at t: TimeInterval) {
        if startedAt == nil { startedAt = t }
        if isVoice(level) { lastVoiceAt = t }
        let dt = Float(max(0, t - (lastSampleAt ?? t)))
        lastSampleAt = t
        if level < noiseFloor {
            noiseFloor += (level - noiseFloor) * Self.fallRate
        } else {
            noiseFloor = min(level, noiseFloor + risePerSecond * dt)
        }
    }

    /// New words from the recogniser also count as voice.
    public mutating func heardWords(at t: TimeInterval) {
        if startedAt == nil { startedAt = t }
        lastVoiceAt = t
    }

    public func shouldStop(at t: TimeInterval, hasWords: Bool) -> Bool {
        guard let startedAt else { return false }
        if t - startedAt >= maxDuration { return true }
        guard hasWords, let lastVoiceAt else { return false }
        return t - lastVoiceAt >= silence
    }
}

// MARK: - Morning

public enum MorningRules {
    /// "patient. ship one thing" → "Patient. ship one thing." Trimmed, first letter capitalised,
    /// ends with punctuation.
    public static func intention(from spoken: String) -> String {
        var text = collapse(spoken)
        guard !text.isEmpty else { return "" }
        text = capitalisedFirst(text)
        if let last = text.last, !".!?…".contains(last) { text += "." }
        return text
    }

    /// "call Lena about the pilot." → "Call Lena about the pilot". Step titles carry no full stop.
    public static func stepTitle(from spoken: String) -> String {
        var text = collapse(spoken)
        while text.hasSuffix(".") { text.removeLast() }
        return capitalisedFirst(text.trimmingCharacters(in: .whitespaces))
    }

    /// Why it matters (B7): kept as said, tidied like an intention.
    public static func why(from spoken: String) -> String { intention(from: spoken) }

    /// The meta line under a suggested step: "Keep close friends · 1 step this week",
    /// "Earn my first million · about 2 minutes". Counts are totals, never streaks.
    public static func planMeta(partTitle: String?, hint: String?, stepsThisWeek: Int) -> String {
        let tail: String
        if let hint, !hint.isEmpty {
            tail = hint
        } else {
            switch stepsThisWeek {
            case 0: tail = "no steps this week"
            case 1: tail = "1 step this week"
            default: tail = "\(stepsThisWeek) steps this week"
            }
        }
        guard let partTitle, !partTitle.isEmpty else { return tail }
        return "\(partTitle) · \(tail)"
    }

    /// “Patient. Ship one thing.” — the intention as the subject line on B3–B5.
    public static func quoted(_ text: String) -> String { "“\(text)”" }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    static func capitalisedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

extension DayEngine {
    /// How today's morning ritual plans, whether or not it has been handled yet. The ritual keeps
    /// using this after the intention is saved (which already counts as "handled").
    public func morningPlan(at now: Date, snapshot: CompassSnapshot) -> MorningPlan? {
        guard let goal = snapshot.goal, goal.status == .active else { return nil }
        let todayKey = DayKey(now, calendar: calendar)
        return morningPlan(goal: goal, today: todayKey, time: TimeOfDay(now, calendar: calendar),
                           quietDays: quietDays(before: todayKey, snapshot: snapshot), snapshot: snapshot)
    }

    /// The part a new step counts toward unless the user picks another: the quietest one.
    public func defaultPartID(at now: Date, snapshot: CompassSnapshot) -> UUID? {
        guard let goal = snapshot.goal else { return nil }
        let key = DayKey(now, calendar: calendar)
        return quietestPart(goal: goal, snapshot: snapshot, endingBefore: key)?.id ?? goal.activeParts.first?.id
    }
}

// MARK: - Evening

public enum ReflectionRules {
    /// The prompt that greys while you speak (D3, D4, D2b, D2 → yes).
    public static func question(outcome: ReflectionOutcome, kind: EveningKind) -> String {
        if outcome == .notToday { return "What got in the way?" }
        switch kind {
        case .doneEarlier: return "Anything to add?"
        case .noStep: return "What did you do?"
        case .stepOpen: return "What happened?"
        }
    }

    /// The first save, the moment recording stops (or typing is saved). Audio is always kept.
    /// - transcriptionFailed: on-device speech to text failed or wasn't available.
    public static func draft(
        outcome: ReflectionOutcome,
        transcript: String,
        recording: Recording?,
        transcriptionFailed: Bool,
        partID: UUID?,
        now: Date,
        device: String? = "This iPhone"
    ) -> Reflection {
        let text = MorningRules.collapse(transcript)
        let failed = transcriptionFailed && text.isEmpty && recording != nil
        return Reflection(
            outcome: outcome,
            transcript: text,
            summary: nil,
            summaryState: failed ? .transcriptionFailed : .ready,
            duration: recording?.duration,
            partID: partID,
            createdAt: now,
            device: device,
            audioFileName: recording?.fileName
        )
    }

    /// Audio is saved but there are no words yet: transcribe the file (Try again, D6b).
    public static func needsTranscription(_ r: Reflection) -> Bool {
        r.transcript.isEmpty && r.audioFileName != nil && r.summary == nil
    }

    /// Words exist but no summary yet: ask the cloud (if the switch is on). Also after reconnecting (D6).
    public static func needsSummary(_ r: Reflection) -> Bool {
        r.summary == nil && !r.transcript.isEmpty && r.summaryState != .transcriptionFailed
    }

    /// Result of transcribing the saved recording. nil or empty = failed (D6b).
    public static func applying(transcript: String?, to r: Reflection) -> Reflection {
        var r = r
        let text = MorningRules.collapse(transcript ?? "")
        if text.isEmpty {
            r.summaryState = .transcriptionFailed
        } else {
            r.transcript = text
            r.summaryState = .ready
        }
        return r
    }

    /// Result of asking the cloud for a summary.
    /// - success: the summary takes the question's place (D5).
    /// - disabled: plain transcript, no summary (cloud help is off).
    /// - offline: "Saved as audio." with the reconnect notice (D6); the text waits.
    public static func applying(summary result: Result<String, CloudAssistError>, to r: Reflection) -> Reflection {
        var r = r
        switch result {
        case .success(let s):
            let text = MorningRules.collapse(s)
            r.summary = text.isEmpty ? nil : text
            r.summaryState = .ready
        case .failure(.disabled):
            r.summary = nil
            r.summaryState = .ready
        case .failure(.offline):
            r.summaryState = .waitingForNetwork
        }
        return r
    }

    /// A failed summary call, by kind (`CloudAssistFailure`):
    /// - offline: wait for the network (D6); the app retries on reconnect;
    /// - disabled, or a server/decoding error: the plain transcript stands, never "Offline".
    public static func applying(summaryError error: Error, to r: Reflection) -> Reflection {
        switch CloudAssistFailure(error) {
        case .offline: return applying(summary: .failure(.offline), to: r)
        case .disabled, .server: return applying(summary: .failure(.disabled), to: r)
        }
    }

    /// A reflection waiting for the network (D6) that a reconnect should retry.
    public static func waitsForNetwork(_ r: Reflection?) -> Bool {
        r?.summaryState == .waitingForNetwork
    }

    /// "Type a summary" (D6b) or the pen (D5): typed text becomes the summary; the recording stays.
    public static func applying(typedSummary: String, to r: Reflection) -> Reflection {
        var r = r
        let text = MorningRules.collapse(typedSummary)
        guard !text.isEmpty else { return r }
        r.summary = text
        r.summaryState = .ready
        return r
    }

    /// The text in the 224 slot once saved.
    public static func title(for r: Reflection) -> String {
        switch r.summaryState {
        case .waitingForNetwork, .transcriptionFailed:
            return "Saved as audio."
        case .ready:
            if let s = r.summary { return s }
            if !r.transcript.isEmpty { return r.transcript }
            return r.outcome == .moved ? "Done." : "Not today."
        }
    }

    /// The Transcript row shows only when the title is a summary of something longer.
    public static func showsTranscript(_ r: Reflection) -> Bool {
        r.summaryState == .ready && r.summary != nil && !r.transcript.isEmpty
    }

    /// Edit (pen) is offered once there is text to edit.
    public static func canEdit(_ r: Reflection) -> Bool { r.summaryState == .ready }
}

// MARK: - Fixture copy for the ritual boards

extension Fixtures {
    /// D3L live words (morning/evening boards), without the trailing pending word "coming".
    public static let longLiveTranscript = "Texted Sam. Friday is on, his place, and Priya is coming. She’s moving to Lisbon in March, so this might be one of the last easy ones. I want to book a weekend there before she goes, maybe the second week of February, and tell her on Friday. Also, the wine she liked last time was the Douro red, so I should pick some up on the way, and ask Sam if his brother is"

    /// The suggested step drawn on B3 and B6.
    public static func stepIdea(for id: ScreenID) -> StepIdea? {
        switch id {
        case .b3: return StepIdea(title: stepTitle, partID: friendsPartID)
        case .b6: return StepIdea(title: afternoonStepTitle, partID: wealthPartID, hint: "about 2 minutes")
        default: return nil
        }
    }
}
