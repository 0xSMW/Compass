import Foundation
import AVFoundation
import Observation

/// Plays saved memos for the `Player` component (D5, D6, E2…) and reads their mini waveform.
/// One memo plays at a time. Missing files (fixtures, screenshots) are a quiet no-op.
@MainActor
@Observable
final class VoicePlayback {
    static let shared = VoicePlayback()

    /// The file currently playing, if any.
    private(set) var playingFile: String?
    /// Mini-waveform bars per file (20 bars, 0...1), computed off the main thread.
    private(set) var waveforms: [String: [Float]] = [:]

    @ObservationIgnored private var player: AVAudioPlayer?
    private let delegate = PlayerDelegate()
    @ObservationIgnored private var loading: Set<String> = []
    private let storage: VoiceStorage

    init(storage: VoiceStorage = .shared) {
        self.storage = storage
    }

    func isPlaying(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return playingFile == fileName
    }

    /// Play, or pause if this memo is already playing.
    func toggle(_ fileName: String?) {
        guard let fileName else { return }
        if playingFile == fileName {
            stop()
            return
        }
        stop()
        guard storage.exists(fileName) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: storage.url(for: fileName))
            delegate.onFinish = { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.finished() }
            }
            player.delegate = delegate
            player.prepareToPlay()
            player.play()
            self.player = player
            playingFile = fileName
        } catch {
            playingFile = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if playingFile != nil {
            playingFile = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func finished() {
        player = nil
        playingFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Bars for the player's mini waveform, or nil while loading / when the file is missing.
    func waveform(for fileName: String?, bars: Int = 20) -> [Float]? {
        guard let fileName else { return nil }
        if let cached = waveforms[fileName] { return cached }
        guard storage.exists(fileName), !loading.contains(fileName) else { return nil }
        loading.insert(fileName)
        let url = storage.url(for: fileName)
        Task.detached(priority: .utility) {
            let levels = VoicePlayback.readLevels(url: url, bars: bars)
            await self.storeWaveform(levels, for: fileName)
        }
        return nil
    }

    private func storeWaveform(_ levels: [Float]?, for fileName: String) {
        loading.remove(fileName)
        if let levels { waveforms[fileName] = levels }
    }

    nonisolated static func readLevels(url: URL, bars: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, bars > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return nil }
        let samples = data[0]
        let count = Int(buffer.frameLength)
        let chunk = max(1, count / bars)
        var result: [Float] = []
        for b in 0..<bars {
            let start = b * chunk
            guard start < count else { result.append(0); continue }
            let end = min(count, start + chunk)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - start)).squareRoot()
            let db = 20 * log10(max(rms, 0.000_01))
            result.append(min(1, max(0.15, (db + 50) / 45)))
        }
        return result
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}
