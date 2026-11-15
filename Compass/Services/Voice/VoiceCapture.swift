import Foundation
import Observation
import CompassCore

/// One spoken answer at a time (intention, step, why, reflection), across the screens that draw it.
///
/// Turn-taking replaces the screen (B1 → B2, D1 → D3), so the take lives here rather than in a view:
/// the view that starts it and the view that shows the live words read the same object.
/// Works with any `AudioRecorder` + `SpeechTranscriber` (live services in the app, fakes in tests).
///
/// - Words land as said (`settled` ink, `pending` dim).
/// - Levels feed the waveform (`levels`, newest last) or the level bar (Reduce Motion).
/// - Stops on silence once words have landed (`onSilence`), or when the view taps stop.
/// - VoiceOver hears "Listening" when it starts; the caller announces "Saved" once it has saved.
@MainActor
@Observable
final class VoiceCapture {
    static let shared = VoiceCapture()

    enum State: Equatable { case idle, starting, listening, stopping }

    /// Why a recording couldn't start. The dock becomes "Type instead" (I1 / I4 copy).
    enum StartError: Error, Equatable {
        case microphoneOff
        case storageFull
        case unavailable
    }

    /// What was said: the saved audio (always kept) and the words, if speech-to-text worked.
    struct Take {
        var recording: Recording?
        var transcript: String
        /// No words came out (on-device recognition failed, unavailable, or heard nothing).
        var transcriptionFailed: Bool
    }

    static let barCount = 38

    private(set) var state: State = .idle
    private(set) var settled = ""
    private(set) var pending = ""
    private(set) var levels: [Float] = []

    /// Called once when the speaker goes quiet after talking. The view saves, as if stop was tapped.
    @ObservationIgnored var onSilence: (() -> Void)?

    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var silence = SilenceDetector()
    @ObservationIgnored private var startedAt = Date()
    /// Bumped by every start and by a stop during `.starting`. A start that finds the generation
    /// changed after one of its awaits was cancelled: it stops its own recorder and returns false,
    /// so no take keeps listening without an owner.
    @ObservationIgnored private var generation = 0

    var text: String { TranscriptUpdate(settled: settled, pending: pending).text }
    var isListening: Bool { state == .listening }
    var isBusy: Bool { state != .idle }

    private var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Ask for the microphone (and speech) if needed, then record and transcribe.
    /// Speech permission is optional: without it the audio is still saved and typing fills in.
    /// Returns false (and does nothing) when a take is already starting or running.
    @discardableResult
    func start(recorder: AudioRecorder, transcriber: SpeechTranscriber) async throws -> Bool {
        guard state == .idle else { return false }
        state = .starting
        generation += 1
        let mine = generation
        /// Still this start's turn (no stop or newer start came in during an await).
        var current: Bool { self.generation == mine && self.state == .starting }
        VoicePlayback.shared.stop()

        var mic = recorder.permission
        if mic == .notDetermined { mic = await recorder.requestPermission() }
        guard current else { return false }
        guard mic == .granted else {
            state = .idle
            throw StartError.microphoneOff
        }
        var speech = transcriber.permission
        if speech == .notDetermined { speech = await transcriber.requestPermission() }
        guard current else { return false }

        settled = ""
        pending = ""
        levels = []
        silence = SilenceDetector()
        startedAt = Date()
        self.recorder = recorder

        // Subscribe to words before the first buffer arrives.
        if speech == .granted {
            let stream = transcriber.live()
            transcriptTask = Task { [weak self] in
                do {
                    for try await update in stream {
                        self?.apply(update)
                    }
                } catch {
                    // Failure shows up as an empty transcript at stop (D6b / typing).
                }
            }
        }

        do {
            try await recorder.start()
        } catch {
            guard current else { return false }
            transcriptTask?.cancel()
            transcriptTask = nil
            self.recorder = nil
            state = .idle
            switch error as? RecorderError {
            case .permissionDenied?: throw StartError.microphoneOff
            case .storageFull?: throw StartError.storageFull
            default: throw StartError.unavailable
            }
        }

        guard current else {
            // Stopped (Close, Back) while the recorder was starting: nothing to keep. `stop()` already
            // reset the state; end this recorder's take and remove its file, unless a newer start
            // has the recorder by now.
            if self.generation == mine + 1, self.state == .idle {
                let orphan = try? await recorder.stop()
                VoiceStorage.shared.delete(orphan?.fileName)
            }
            return false
        }
        state = .listening
        Feedback.announce("Listening")

        let levelStream = recorder.levels()
        levelTask = Task { [weak self] in
            for await level in levelStream {
                self?.feed(level)
            }
            // The level stream only ends on its own when the recorder ended the take (a phone call, the
            // headset unplugged). Save what was said, exactly as after a pause.
            guard !Task.isCancelled, let self, self.state == .listening else { return }
            self.onSilence?()
        }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.state == .listening else { return }
                if self.silence.shouldStop(at: self.elapsed, hasWords: !self.text.isEmpty) {
                    self.onSilence?()
                    return
                }
            }
        }
        return true
    }

    /// Stop recording, wait briefly for the last words, and hand back the take.
    func stop() async -> Take {
        if state == .starting {
            // The recorder isn't running yet. Cancel the start (it cleans up after its await) and
            // hand back an empty take; nothing was recorded.
            generation += 1
            transcriptTask?.cancel()
            transcriptTask = nil
            recorder = nil
            state = .idle
            return Take(recording: nil, transcript: "", transcriptionFailed: true)
        }
        guard state == .listening else {
            return Take(recording: nil, transcript: text, transcriptionFailed: text.isEmpty)
        }
        state = .stopping
        watchTask?.cancel()
        watchTask = nil
        let recording = try? await recorder?.stop()
        levelTask?.cancel()
        levelTask = nil
        if let words = transcriptTask {
            // The recogniser finalises after endAudio(); don't wait forever for it.
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                words.cancel()
            }
            await words.value
            timeout.cancel()
        }
        transcriptTask = nil
        recorder = nil
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        return Take(recording: recording, transcript: words, transcriptionFailed: words.isEmpty)
    }

    /// Stop and throw the audio away (leaving a flow without keeping anything).
    func discard() async {
        let take = await stop()
        VoiceStorage.shared.delete(take.recording?.fileName)
        settled = ""
        pending = ""
        levels = []
    }

    private func apply(_ update: TranscriptUpdate) {
        let changed = update.text != text
        settled = update.settled
        pending = update.pending
        if changed, !update.text.isEmpty { silence.heardWords(at: elapsed) }
    }

    private func feed(_ level: Float) {
        levels.append(level)
        if levels.count > Self.barCount { levels.removeFirst(levels.count - Self.barCount) }
        silence.feed(level: level, at: elapsed)
    }
}
