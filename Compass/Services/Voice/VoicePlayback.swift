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

    /// Frames decoded per read: memory stays at one small buffer however long the memo is.
    nonisolated static let readChunk: AVAudioFrameCount = 16_384
    /// At most this many samples are measured per bar; the rest are skipped (RMS of a sparse sample is
    /// indistinguishable at 20 bars and keeps a 5-minute memo cheap).
    nonisolated static let samplesPerBar = 2_000

    /// RMS per bar, read in chunks and sparsely sampled (never the whole file in memory).
    nonisolated static func readLevels(url: URL, bars: Int) -> [Float]? {
        guard bars > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readChunk) else { return nil }
        let step = max(1, Int(total / AVAudioFramePosition(bars * samplesPerBar)))
        var sums = [Double](repeating: 0, count: bars)
        var counts = [Int](repeating: 0, count: bars)
        var position: AVAudioFramePosition = 0
        while position < total {
            do { try file.read(into: buffer, frameCount: readChunk) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let samples = buffer.floatChannelData?[0] else { break }
            // Continue the stride across chunk boundaries.
            var i = Int((AVAudioFramePosition(step) - position % AVAudioFramePosition(step)) % AVAudioFramePosition(step))
            while i < n {
                let frame = position + AVAudioFramePosition(i)
                let bar = min(bars - 1, Int(frame * AVAudioFramePosition(bars) / total))
                let x = Double(samples[i])
                sums[bar] += x * x
                counts[bar] += 1
                i += step
            }
            position += AVAudioFramePosition(n)
        }
        guard counts.contains(where: { $0 > 0 }) else { return nil }
        return (0..<bars).map { b in
            guard counts[b] > 0 else { return 0 }
            let rms = Float((sums[b] / Double(counts[b])).squareRoot())
            let db = 20 * log10(max(rms, 0.000_01))
            return min(1, max(0.15, (db + 50) / 45))
        }
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
