import SwiftUI
import CompassCore

// Notices about the day take the notes row above the Today card, so the card never moves (system.html).

/// I2 · "07:00 and 21:00 can’t reach you." · Turn on · ×. One notice until dismissed.
struct SystemNotificationsNotice: View {
    var rhythm: Rhythm
    var onTurnOn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Icon(.bell, size: IconSize.s).foregroundStyle(.ink2)
            Text("\(rhythm.morning.description) and \(rhythm.evening.description) can’t reach you.")
                .compassFont(.caption)
                .foregroundStyle(.noticeInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onTurnOn) {
                Text("Turn on")
                    .compassFont(.body, weight: .medium)
                    .foregroundStyle(.ink)
                    .padding(.horizontal, Space.xs)
                    .frame(minHeight: 44)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Turn on notifications")
            Button(action: onDismiss) {
                Icon(.x, size: IconSize.xs)
                    .foregroundStyle(.ink2)
                    .frame(width: ControlSize.minTarget, height: ControlSize.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, Space.xs)
        .padding(.leading, Space.s)
        .padding(.trailing, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// I3 · "You’re in Tokyo. Today and your 07:00 and 21:00 now follow Tokyo time." · OK · Keep Bangkok time.
struct SystemTimeZoneNotice: View {
    var change: TimeZoneChange
    var rhythm: Rhythm
    var onOK: () -> Void
    var onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .top, spacing: Space.xs) {
                Icon(.globe, size: IconSize.s).foregroundStyle(.ink2)
                Text("You’re in \(change.currentCity). Today and your \(rhythm.morning.description) and \(rhythm.evening.description) now follow \(change.currentCity) time.")
                    .compassFont(.caption)
                    .foregroundStyle(.noticeInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                link("OK", action: onOK)
                    .accessibilityLabel("OK, follow \(change.currentCity) time")
                link("Keep \(change.previousCity) time", action: onKeep)
            }
            .padding(.leading, 28)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .compassFont(.body, weight: .medium)
                .foregroundStyle(.ink)
                .frame(minHeight: 44)
        }
        .buttonStyle(PressableStyle())
    }
}

/// I1 / I4 notices for the place the user is looking (focal slot, or Today's notes row).
struct SystemRecordingNotice: View {
    var block: RecordingBlock
    /// Today shows the fix as a link inside the notice; I1/I4 put it under the Type instead button.
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
