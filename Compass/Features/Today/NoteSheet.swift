import SwiftUI
import CompassCore

/// A note, opened from Today's notes row, Today's notes list or a past day (E2). Built like C6's step
/// options: the words, the recording in the design-system `Player` (a voice note starts playing as
/// the sheet opens), then Edit note · Delete note · Close. Editing happens in the sheet, so Today and
/// History share one path. A voice note with no words yet opens straight into "Add words".
struct NoteDetailSheet: View {
    let note: Note
    var startsEditing: Bool = false
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var playback: VoicePlayback { .shared }

    private var audioFile: String? {
        guard let file = MemoAudio.fileName(for: note), VoiceStorage.shared.exists(file) else { return nil }
        return file
    }

    private var needsWords: Bool { NoteRules.needsWords(note) }

    /// 24 above, the words (up to 120), the player (80 + 16) when there is audio, two rows, Close.
    static func height(for note: Note) -> CGFloat {
        let hasAudio = MemoAudio.fileName(for: note).map { VoiceStorage.shared.exists($0) } ?? false
        return 24 + 120 + Space.s + (hasAudio ? ControlSize.player + Space.s : 0) + 2 * 56 + 20 + 48 + 52
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editing {
                editor
            } else {
                reading
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if startsEditing || (needsWords && audioFile == nil) {
                startEditing()
            } else if let audioFile, !playback.isPlaying(audioFile) {
                playback.toggle(audioFile)
            }
        }
        .onDisappear { playback.stop() }
    }

    @ViewBuilder
    private var reading: some View {
        ScrollView {
            Text(needsWords ? "Voice note. No words yet." : note.text)
                .compassFont(.body)
                .foregroundStyle(needsWords ? Color.ink3 : Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 120, alignment: .top)

        if let audioFile, let duration = note.duration {
            Player(duration: duration, isPlaying: playback.isPlaying(audioFile),
                   levels: playback.waveform(for: audioFile) ?? Array(FakeAudioRecorder.designLevels.prefix(20)),
                   showsRedo: false) {
                playback.toggle(audioFile)
            }
            .padding(.top, Space.s)
        }

        VStack(spacing: 0) {
            ListRow(icon: .pen, title: needsWords ? "Add words" : "Edit note", action: { startEditing() })
            ListRow(icon: .trash, title: "Delete note", action: {
                playback.stop()
                onDelete()
            })
            .accessibilityHint(note.isSpoken ? "Deletes the note and its recording" : "Deletes the note")
        }
        .padding(.top, Space.s)

        Spacer().frame(height: 20)
        LinkButton("Close") { onClose() }
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var editor: some View {
        TextField("", text: $draft, prompt: Text(needsWords ? "Add words to this voice note" : "Note").foregroundStyle(Color.dim),
                  axis: .vertical)
            .focused($focused)
            .lineLimit(3...5)
            .compassFont(.body)
            .foregroundStyle(.ink)
            .tint(.ink)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 12)
            .background(Color.ground, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Color.line2, lineWidth: 1))
            .accessibilityLabel(needsWords ? "Words for this voice note" : "Note")

        Spacer(minLength: Space.s)

        PrimaryButton("Save") {
            focused = false
            onSave(draft)
        }
        .disabled(!note.isSpoken && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        LinkButton("Cancel") {
            focused = false
            if startsEditing { onClose() } else { editing = false }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, Space.m)
    }

    private func startEditing() {
        playback.stop()
        draft = note.text
        editing = true
        DispatchQueue.main.async { focused = true }
    }
}

// MARK: - Note actions (Today and History)

extension AppModel {
    /// A finished note recording (C5). The note keeps the recording's id, so its audio stays at
    /// `<note id>.m4a` and plays back. Returns the saved note; nil when nothing was recorded or said.
    @discardableResult
    func saveVoiceNote(transcript: String, recording: Recording?) -> Note? {
        guard let note = NoteRules.note(transcript: transcript, recording: recording, now: now, device: SyncDevice.label) else {
            return nil
        }
        updateToday { $0.notes.append(note) }
        return note
    }

    /// Edit a note's words on any day. A typed note emptied out is removed (with nothing to delete).
    func editNote(_ id: UUID, on key: DayKey, text: String) {
        updateDay(key) { $0.editNote(id, text: text) }
    }

    /// Delete a note and its recording.
    func deleteNote(_ id: UUID, on key: DayKey) {
        guard let note = snapshot.day(key)?.notes.first(where: { $0.id == id }) else { return }
        let file = MemoAudio.fileName(for: note)
        if VoicePlayback.shared.isPlaying(file) { VoicePlayback.shared.stop() }
        updateDay(key) { $0.removeNote(id) }
        VoiceStorage.shared.delete(file)
    }
}
