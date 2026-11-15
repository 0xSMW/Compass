import Foundation

/// Deterministic recorder. Emits a fixed level pattern (the design's waveform heights / 40).
public final class FakeAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSLock()
    public var permission: PermissionState
    public var storageFull: Bool
    public var duration: TimeInterval
    public private(set) var isRecording = false
    public var startedAt: Date

    /// Bar heights from the design (kit PRELUDE `H`), normalised to 0...1.
    public static let designLevels: [Float] = [10,18,30,22,40,40,34,26,40,40,36,20,14,28,40,40,30,24,38,40,32,18,12,28,40,36,22,10,8,6,12,20,30,24,16,10,8,6,6,6].map { Float($0) / 40 }

    public init(permission: PermissionState = .granted, storageFull: Bool = false, duration: TimeInterval = 14, startedAt: Date = Fixtures.referenceDate) {
        self.permission = permission
        self.storageFull = storageFull
        self.duration = duration
        self.startedAt = startedAt
    }

    public func requestPermission() async -> PermissionState { permission }

    public func start() async throws {
        if permission != .granted { throw RecorderError.permissionDenied }
        if storageFull { throw RecorderError.storageFull }
        lock.withLock { isRecording = true }
    }

    public func levels() -> AsyncStream<Float> {
        AsyncStream { continuation in
            for level in Self.designLevels { continuation.yield(level) }
            continuation.finish()
        }
    }

    public func stop() async throws -> Recording {
        let wasRecording = lock.withLock { () -> Bool in
            let was = isRecording
            isRecording = false
            return was
        }
        guard wasRecording else { throw RecorderError.notRecording }
        return Recording(duration: duration, fileName: "fake.m4a", createdAt: startedAt)
    }
}

/// Deterministic transcriber: emits `script` word by word, last word pending until final.
public final class FakeSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    public var permission: PermissionState
    public var script: String
    public var fails: Bool

    public init(script: String = Fixtures.reflectionTranscript, permission: PermissionState = .granted, fails: Bool = false) {
        self.script = script
        self.permission = permission
        self.fails = fails
    }

    public func requestPermission() async -> PermissionState { permission }

    /// All updates for `script`, in order (useful for previews and tests).
    public static func updates(for script: String) -> [TranscriptUpdate] {
        let words = script.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [TranscriptUpdate(settled: "", isFinal: true)] }
        var result: [TranscriptUpdate] = []
        for i in 0..<words.count {
            result.append(TranscriptUpdate(settled: words[..<i].joined(separator: " "), pending: words[i]))
        }
        result.append(TranscriptUpdate(settled: words.joined(separator: " "), isFinal: true))
        return result
    }

    public func live() -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let script = self.script, fails = self.fails, permission = self.permission
        return AsyncThrowingStream { continuation in
            if permission != .granted { continuation.finish(throwing: TranscriberError.permissionDenied); return }
            if fails { continuation.finish(throwing: TranscriberError.failed); return }
            for u in Self.updates(for: script) { continuation.yield(u) }
            continuation.finish()
        }
    }

    public func transcribe(_ recording: Recording) async throws -> String {
        if fails { throw TranscriberError.failed }
        return script
    }
}

/// Deterministic cloud assist. Summaries and ideas come from `Fixtures`.
public final class FakeCloudAssist: CloudAssist, @unchecked Sendable {
    public var isEnabled: Bool
    public var isOnline: Bool
    public var summaries: [String: String]

    public init(isEnabled: Bool = true, isOnline: Bool = true, summaries: [String: String] = Fixtures.summaries) {
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.summaries = summaries
    }

    private func check() throws {
        if !isEnabled { throw CloudAssistError.disabled }
        if !isOnline { throw CloudAssistError.offline }
    }

    public func summarize(transcript: String, goal: Goal?) async throws -> String {
        try check()
        if let s = summaries[transcript] { return s }
        // First sentence, trimmed: deterministic and short.
        let first = transcript.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? transcript
        return first.trimmingCharacters(in: .whitespaces) + "."
    }

    public func suggestStep(goal: Goal, part: GoalPart?, size: StepSize, recent: [Day]) async throws -> StepIdea {
        try check()
        switch (part?.symbol, size) {
        case (_, .smaller): return StepIdea(title: Fixtures.smallerStepTitle, partID: part?.id, size: .smaller)
        case (.friends?, _): return StepIdea(title: Fixtures.stepTitle, partID: part?.id)
        case (.strength?, _): return StepIdea(title: "Run 5 km", partID: part?.id)
        default: return StepIdea(title: Fixtures.workStepTitle, partID: part?.id)
        }
    }

    public func clarifyingQuestion(for goalText: String) async throws -> String? {
        try check()
        let words = goalText.split(separator: " ")
        return words.count <= 3 ? "What would happier look like a year from now?" : nil
    }

    public func proposeParts(for goalText: String) async throws -> [GoalPart] {
        try check()
        return Fixtures.parts
    }
}
