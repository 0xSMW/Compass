import Foundation
import AVFoundation
import CompassCore

/// Errors from the audio session or input that the CompassCore protocol has no case for.
enum LiveVoiceError: Error, Equatable {
    /// No usable microphone input (simulator without input, route lost).
    case noInput
}

/// The live recorder: one `AVAudioEngine` input tap that
/// - writes AAC (`.m4a`) to `VoiceStorage` (Application Support, on the phone),
/// - reports a normalised input level (0...1) for the waveform / level bar,
/// - hands every buffer to consumers, so the on-device transcriber hears the same audio
///   without opening the microphone twice (`LiveSpeechTranscriber` registers as a consumer).
final class LiveAudioRecorder: AudioRecorder, @unchecked Sendable {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    private struct Consumer {
        let onBuffer: BufferHandler
        let onEnd: () -> Void
    }

    private struct Take {
        let id: UUID
        let fileName: String
        let startedAt: Date
        let sampleRate: Double
    }

    private let lock = NSLock()
    private let storage: VoiceStorage
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var take: Take?
    private var framesWritten: AVAudioFramePosition = 0
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var consumers: [UUID: Consumer] = [:]

    init(storage: VoiceStorage = .shared) {
        self.storage = storage
    }

    // MARK: Permission

    var permission: PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestPermission() async -> PermissionState {
        if permission != .notDetermined { return permission }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        return granted ? .granted : .denied
    }

    var isRecording: Bool { lock.withLock { engine != nil } }

    // MARK: Consumers (the transcriber)

    /// Receive every input buffer while recording; `onEnd` runs once when recording stops.
    func addConsumer(onBuffer: @escaping BufferHandler, onEnd: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { consumers[id] = Consumer(onBuffer: onBuffer, onEnd: onEnd) }
        return id
    }

    func removeConsumer(_ id: UUID) {
        lock.withLock { consumers[id] = nil }
    }

    // MARK: Recording

    func start() async throws {
        guard permission == .granted else { throw RecorderError.permissionDenied }
        guard storage.hasRoomForRecording else { throw RecorderError.storageFull }
        if isRecording { _ = try? await stop() }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw LiveVoiceError.noInput
        }

        let id = UUID()
        let fileName = storage.fileName(for: id)
        let url = storage.url(for: fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if storage.hasRoomForRecording { throw error }
            throw RecorderError.storageFull
        }

        lock.withLock {
            self.file = file
            self.take = Take(id: id, fileName: fileName, startedAt: Date(), sampleRate: format.sampleRate)
            self.framesWritten = 0
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                self.file = nil
                self.take = nil
            }
            storage.delete(fileName)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        lock.withLock { self.engine = engine }
    }

    func levels() -> AsyncStream<Float> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            let active = lock.withLock { () -> Bool in
                guard take != nil else { return false }
                levelContinuations[id] = continuation
                return true
            }
            if !active { continuation.finish(); return }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.levelContinuations[id] = nil }
            }
        }
    }

    func stop() async throws -> Recording {
        guard let engine = lock.withLock({ self.engine }) else { throw RecorderError.notRecording }
        // Stop the tap first so no buffer is written while the file closes.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let state = lock.withLock { () -> (Take?, AVAudioFramePosition, [Consumer], [AsyncStream<Float>.Continuation]) in
            let result = (take, framesWritten, Array(consumers.values), Array(levelContinuations.values))
            self.engine = nil
            self.file = nil // releasing the AVAudioFile finalises the m4a
            self.take = nil
            self.consumers = [:]
            self.levelContinuations = [:]
            return result
        }
        state.2.forEach { $0.onEnd() }
        state.3.forEach { $0.finish() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let take = state.0 else { throw RecorderError.notRecording }
        let duration = take.sampleRate > 0 && state.1 > 0
            ? Double(state.1) / take.sampleRate
            : Date().timeIntervalSince(take.startedAt)
        return Recording(id: take.id, duration: duration, fileName: take.fileName, createdAt: take.startedAt)
    }

    // MARK: Tap

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let (file, consumers, continuations) = lock.withLock {
            (self.file, Array(self.consumers.values), Array(self.levelContinuations.values))
        }
        if let file {
            do {
                try file.write(from: buffer)
                lock.withLock { framesWritten += AVAudioFramePosition(buffer.frameLength) }
            } catch {
                // A failed write (disk full mid-take) keeps what was written; transcription continues.
            }
        }
        let level = Self.level(of: buffer)
        continuations.forEach { $0.yield(level) }
        consumers.forEach { $0.onBuffer(buffer) }
    }

    /// RMS of the first channel mapped from -50…-5 dBFS to 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = data[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (db + 50) / 45))
    }
}
