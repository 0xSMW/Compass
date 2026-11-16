import Foundation
import CompassCore

/// Live voice services for the real app path (no `-screen`): an AVAudioEngine recorder that writes
/// m4a on the phone and an on-device SFSpeechRecognizer transcriber that listens to the same audio.
/// Fixtures and screenshots keep using `FakeAudioRecorder` / `FakeSpeechTranscriber` (see AppModel).
enum LiveVoiceServices {
    static func make() -> (recorder: AudioRecorder, transcriber: SpeechTranscriber) {
        let recorder = LiveAudioRecorder()
        return (recorder, LiveSpeechTranscriber(source: recorder))
    }
}
