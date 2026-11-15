import SwiftUI
import CompassCore

// Notices about the day take the notes row above the Today card, so the card never moves (system.html).
// All of them are the design system's `Notice`.

/// I2 · "07:00 and 21:00 can’t reach you." · Turn on · ×. One notice until dismissed.
struct SystemNotificationsNotice: View {
    var rhythm: Rhythm
    var onTurnOn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Notice(icon: .bell, text: "\(rhythm.morning.description) and \(rhythm.evening.description) can’t reach you.",
               actions: [NoticeAction(title: "Turn on", label: "Turn on notifications", action: onTurnOn)],
               layout: .inline, onDismiss: onDismiss)
    }
}

/// I3 · "You’re in Tokyo. Today and your 07:00 and 21:00 now follow Tokyo time." · OK · Keep Bangkok time.
struct SystemTimeZoneNotice: View {
    var change: TimeZoneChange
    var rhythm: Rhythm
    var onOK: () -> Void
    var onKeep: () -> Void

    var body: some View {
        Notice(icon: .globe,
               text: "You’re in \(change.currentCity). Today and your \(rhythm.morning.description) and \(rhythm.evening.description) now follow \(change.currentCity) time.",
               actions: [NoticeAction(title: "OK", label: "OK, follow \(change.currentCity) time", action: onOK),
                         NoticeAction(title: "Keep \(change.previousCity) time", action: onKeep)])
    }
}

/// Recording can't start (microphone off, storage full), in Today's notes row after tapping Note, with
/// the fix as a link inside the notice. The rituals put the fix under "Type instead" (`TypeInsteadDock`).
struct SystemRecordingNotice: View {
    var block: RecordingBlock
    var showsAction: Bool = false
    var onAction: () -> Void = {}

    var body: some View {
        switch block {
        case .microphoneOff:
            Notice(icon: .micoff, text: "The microphone is off for Compass.",
                   actionTitle: showsAction ? "Turn on the microphone" : nil, action: onAction)
        case .storageFull:
            Notice(icon: .disk, text: "Your iPhone is full, so audio can’t be saved. Typing still works, and nothing you saved before is affected.",
                   actionTitle: showsAction ? "Manage storage" : nil, action: onAction)
        }
    }
}
