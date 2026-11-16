import Foundation

// MARK: - Recording

/// A saved audio clip. Audio is stored on the phone; only text goes to the cloud (when the switch is on).
public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var duration: TimeInterval
    public var fileName: String
    public var createdAt: Date

    public init(id: UUID = UUID(), duration: TimeInterval, fileName: String, createdAt: Date) {
        self.id = id
        self.duration = duration
        self.fileName = fileName
        self.createdAt = createdAt
    }
}

public enum PermissionState: String, Codable, Hashable, Sendable {
    case notDetermined
    case granted
    case denied
}

public enum RecorderError: Error, Equatable, Sendable {
    /// I1: "The microphone is off for Compass." The dock becomes "Type instead".
    case permissionDenied
    /// I4: "Your iPhone is full, so audio can't be saved."
    case storageFull
    case notRecording
}

/// Records audio and reports input level (0...1) for the waveform / level bar.
public protocol AudioRecorder: AnyObject, Sendable {
    var permission: PermissionState { get }
    func requestPermission() async -> PermissionState
    func start() async throws
    /// Normalised levels while recording. Finishes when recording stops.
    func levels() -> AsyncStream<Float>
    func stop() async throws -> Recording
}

// MARK: - Speech to text (on the phone)

public struct TranscriptUpdate: Hashable, Sendable {
    /// Words that won't change any more (ink).
    public var settled: String
    /// The trailing word still being recognised (dim, #6E6E74).
    public var pending: String
    public var isFinal: Bool

    public init(settled: String, pending: String = "", isFinal: Bool = false) {
        self.settled = settled
        self.pending = pending
        self.isFinal = isFinal
    }

    public var text: String { pending.isEmpty ? settled : (settled.isEmpty ? pending : settled + " " + pending) }
}

public enum TranscriberError: Error, Equatable, Sendable {
    case permissionDenied
    /// D6b: "Couldn't turn this recording into text."
    case failed
}

/// On-device speech to text. Words land as said; stops on silence.
public protocol SpeechTranscriber: AnyObject, Sendable {
    var permission: PermissionState { get }
    func requestPermission() async -> PermissionState
    /// Live updates while the user speaks.
    func live() -> AsyncThrowingStream<TranscriptUpdate, Error>
    /// Transcribe a saved recording (retry path, D6/D6b).
    func transcribe(_ recording: Recording) async throws -> String
}

// MARK: - Cloud assist (behind the one switch)

public enum CloudAssistError: Error, Equatable, Sendable {
    /// The Settings switch is off: plain transcripts, no ideas.
    case disabled
    /// D6: "Offline. Text and summary appear here when you reconnect."
    case offline
}

public struct StepIdea: Hashable, Sendable {
    public var title: String
    public var partID: UUID?
    public var size: StepSize
    /// "about 2 minutes" (B6) — optional hint shown in the meta line.
    public var hint: String?

    public init(title: String, partID: UUID?, size: StepSize = .regular, hint: String? = nil) {
        self.title = title
        self.partID = partID
        self.size = size
        self.hint = hint
    }
}

/// Summaries and step ideas from a private cloud model. Never trains on the user's notes.
public protocol CloudAssist: AnyObject, Sendable {
    var isEnabled: Bool { get }
    func summarize(transcript: String, goal: Goal?) async throws -> String
    func suggestStep(goal: Goal, part: GoalPart?, size: StepSize, recent: [Day]) async throws -> StepIdea
    /// A1-A4b: one question to make a vague goal concrete, or nil if it is concrete enough.
    func clarifyingQuestion(for goalText: String) async throws -> String?
    /// A5: split the goal into parts and propose symbols.
    func proposeParts(for goalText: String) async throws -> [GoalPart]
}
