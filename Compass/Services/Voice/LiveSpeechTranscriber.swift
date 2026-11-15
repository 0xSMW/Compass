import Foundation
import AVFoundation
import Speech
import CompassCore

/// Speech to text on the phone, never on a server.
///
/// Uses `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. If the language has no
/// on-device model, it fails (`TranscriberError.failed`) instead of falling back to Apple's servers;
/// the evening then shows "Couldn't turn this recording into text." (D6b) and typing still works.
///
/// Live words come from the recorder's own audio buffers (`LiveAudioRecorder.addConsumer`), so the
/// microphone is opened once and the saved m4a and the transcript match.
final class LiveSpeechTranscriber: CompassCore.SpeechTranscriber, @unchecked Sendable {
    private let source: LiveAudioRecorder
    private let storage: VoiceStorage
    private let locale: Locale

    init(source: LiveAudioRecorder, storage: VoiceStorage = .shared, locale: Locale = .current) {
        self.source = source
        self.storage = storage
        self.locale = locale
    }

    // MARK: Permission

    var permission: CompassCore.PermissionState { Self.map(SFSpeechRecognizer.authorizationStatus()) }

    func requestPermission() async -> CompassCore.PermissionState {
        if permission != .notDetermined { return permission }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CompassCore.PermissionState, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> CompassCore.PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// A recogniser for the user's language (English as a fallback) that can run on the phone.
    private func onDeviceRecognizer() -> SFSpeechRecognizer? {
        let candidates = [SFSpeechRecognizer(locale: locale), SFSpeechRecognizer(locale: Locale(identifier: "en-US"))]
        return candidates.compactMap { $0 }.first { $0.supportsOnDeviceRecognition && $0.isAvailable }
    }

    var canTranscribeOnDevice: Bool { onDeviceRecognizer() != nil }

    // MARK: Live

    /// Tracks one live task across the recogniser's callback thread and the recorder's.
    private final class LiveState: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastText = ""
        private var _audioEnded = false
        var lastText: String {
            get { lock.withLock { _lastText } }
            set { lock.withLock { _lastText = newValue } }
        }
        var audioEnded: Bool {
            get { lock.withLock { _audioEnded } }
            set { lock.withLock { _audioEnded = newValue } }
        }
    }

    func live() -> AsyncThrowingStream<CompassCore.TranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            guard permission == .granted else {
                continuation.finish(throwing: CompassCore.TranscriberError.permissionDenied)
                return
            }
            guard let recognizer = onDeviceRecognizer() else {
                continuation.finish(throwing: CompassCore.TranscriberError.failed)
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation

            let state = LiveState()
            let consumer = source.addConsumer(
                onBuffer: { buffer in request.append(buffer) },
                onEnd: {
                    state.audioEnded = true
                    request.endAudio()
                }
            )
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    state.lastText = text
                    continuation.yield(.recognizing(text, isFinal: result.isFinal))
                    if result.isFinal {
                        continuation.finish()
                        return
                    }
                }
                if error != nil {
                    // "No speech detected" or a cancel once the audio has ended is not a failure:
                    // keep the words we have.
                    if !state.lastText.isEmpty {
                        continuation.yield(.recognizing(state.lastText, isFinal: true))
                        continuation.finish()
                    } else if state.audioEnded {
                        continuation.yield(CompassCore.TranscriptUpdate(settled: "", isFinal: true))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CompassCore.TranscriberError.failed)
                    }
                }
            }
            let source = self.source
            continuation.onTermination = { _ in
                source.removeConsumer(consumer)
                withExtendedLifetime(recognizer) { task.cancel() }
            }
        }
    }

    // MARK: Saved recording (Try again)

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?
        var recognizer: SFSpeechRecognizer?
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { body() }
        }
    }

    func transcribe(_ recording: CompassCore.Recording) async throws -> String {
        guard permission == .granted else { throw CompassCore.TranscriberError.permissionDenied }
        guard let recognizer = onDeviceRecognizer() else { throw CompassCore.TranscriberError.failed }
        let url = storage.url(for: recording.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CompassCore.TranscriberError.failed }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let once = Once()
        once.recognizer = recognizer
        let text: String = try await withCheckedThrowingContinuation { continuation in
            once.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { continuation.resume(throwing: CompassCore.TranscriberError.failed) }
                }
            }
        }
        once.task = nil
        once.recognizer = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw CompassCore.TranscriberError.failed }
        return trimmed
    }
}
