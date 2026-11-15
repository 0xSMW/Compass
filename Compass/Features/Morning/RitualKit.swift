import SwiftUI
import UIKit
import CompassCore

// Pieces shared by the Morning (B) and Evening (D) rituals, built only from design-system components.

/// The question greys and the words land under it (B2, D3, D3L, D4). Place with `.region(.focal)`:
/// the transcript fills to 592, then older lines scroll up under a 72pt fade.
struct ListeningFocal: View {
    let question: String
    let settled: String
    var pending: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            CompassText(question, style: .title, color: .ink2)
            TranscriptScroll(settled: settled, pending: pending)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct TranscriptScroll: View {
    let settled: String
    var pending: String = ""

    @State private var overflowing = false

    var body: some View {
        ScrollView {
            LiveTranscript(settled: settled, pending: pending)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentSize.height > geo.containerSize.height + 1
        } action: { _, isOverflowing in
            overflowing = isOverflowing
        }
        .mask {
            if overflowing {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 72)
                    Color.black
                }
            } else {
                Color.black
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// I1 / I4: recording can't start, so the notice sits just above the dock (grows up from 660), "Type
/// instead" takes the 712 line and the fix is a link under it. The one implementation for the live
/// rituals (B1, B4, B7, D3) and the I1/I4 screens, which are those rituals with the microphone off or
/// storage full.
struct TypeInsteadDock: View {
    let reason: VoiceCapture.StartError
    let onType: () -> Void

    var body: some View {
        Group {
            Notice(icon: reason == .storageFull ? .disk : .micoff, text: noticeText, centred: reason != .storageFull)
                .region(.growsUp(bottom: 660))
            PrimaryButton("Type instead", icon: .kb, action: onType)
                .region(.buttonDock)
            LinkButton(linkTitle) { Self.openSettings() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
    }

    private var noticeText: String {
        switch reason {
        case .storageFull: "Your iPhone is full, so audio can’t be saved. Typing still works, and nothing you saved before is affected."
        case .microphoneOff: "The microphone is off for Compass."
        case .unavailable: "The microphone isn’t available right now."
        }
    }

    private var linkTitle: String {
        reason == .storageFull ? "Manage storage" : "Turn on the microphone"
    }

    @MainActor static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Typing in a ritual: the action rides above the keyboard at 436–492. With `drawsKeyboard` (fixture
/// screenshots) the keyboard is drawn; in the app the real keyboard rises underneath.
struct AboveKeyboardAction: View {
    let title: String
    var enabled: Bool = true
    var drawsKeyboard: Bool = false
    let action: () -> Void

    var body: some View {
        Group {
            PrimaryButton(title, action: action)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .region(.aboveKeyboard)
            if drawsKeyboard {
                KeyboardPlaceholder().region(.keyboard)
            }
        }
    }
}

/// The current recording situation for a ritual dock: nil when recording can start. The last failed
/// start, else the microphone permission, else full storage (I1, I4).
@MainActor
func ritualMicProblem(_ model: AppModel, _ last: VoiceCapture.StartError?) -> VoiceCapture.StartError? {
    if let last { return last }
    if model.recorder.permission == .denied || model.conditions.microphone == .denied { return .microphoneOff }
    if model.conditions.storageFull { return .storageFull }
    return nil
}
