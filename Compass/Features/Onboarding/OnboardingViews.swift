import SwiftUI
import UIKit
import CompassCore

// MARK: - Shared pieces

/// Back and the four-step progress in the nav row (onboarding.html `.nav` + `.prog`).
struct OnboardingNav: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID
    var progress: Int?

    var body: some View {
        NavBar(leading: .back { model.onboardingBack(from: id) }, progress: progress)
            .region(.nav)
    }
}

/// Keyboard · mic · empty side on the 712 line (kit.css `.dock`), with the mic labelled for its job.
struct OnboardingVoiceDock: View {
    var micMode: MicButton.Mode
    var micLabel: String
    let onKeyboard: () -> Void
    let onMic: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            CircleButton(.kb, label: "Type instead", action: onKeyboard)
            Spacer(minLength: 0)
            MicButton(mode: micMode, label: micLabel, action: onMic)
            Spacer(minLength: 0)
            Color.clear.frame(width: 56, height: 56).accessibilityHidden(true)
        }
        .frame(height: ControlSize.voice)
        .region(.dock)
    }
}

/// Stand-in for the system keyboard in screenshots (kit.css `.keys`, 508–844). The CI simulator has
/// no software keyboard; on a phone the real one sits here.
struct OnboardingKeyboardPlaceholder: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 12) {
            ForEach(0..<30, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Color.line2).frame(height: 44)
            }
        }
        .padding(.top, Space.xs)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.raised)
        .region(.custom(top: 508, bottom: 844, inset: 0))
        .accessibilityHidden(true)
    }
}

/// The Compass mark on Welcome: 48pt ring (8pt ink border) with a 12pt centre dot.
struct OnboardingMark: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.ink, lineWidth: 8)
            Circle().fill(Color.ink).frame(width: 12, height: 12)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Text that wraps down instead of truncating (titles and hints grow away from controls).
    func onboardingWraps() -> some View { fixedSize(horizontal: false, vertical: true) }
}

/// Asks for mic + speech the first time, then turns to A3; falls back to typing when refused.
@MainActor
private func onboardingStartListening(model: AppModel, draft: OnboardingDraft, answering: Bool, orType: @escaping () -> Void) {
    Task { @MainActor in
        if await model.onboardingVoiceAllowed() {
            draft.answering = answering
            model.replace(with: .a3)
        } else {
            orType()
        }
    }
}

// MARK: - A1 · Welcome

struct OnboardingWelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowScreen {
            OnboardingMark()
                .region(.custom(top: 128, bottom: nil))

            VStack(alignment: .leading, spacing: 0) {
                Text("One goal.\nOne step a day.")
                    .compassFont(.display)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                Text("Say it in the morning. Say what happened at night.")
                    .compassFont(.heading)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                    .padding(.top, Space.m)
            }
            .region(.focal)

            ButtonDock(primary: "Begin", link: "Restore from iCloud", onPrimary: {
                OnboardingDraft.shared.reset()
                model.go(.a2)
            }, onLink: {
                model.go(.r1)
            })
        }
    }
}

// MARK: - A2 · Goal, A8 · Largest text

/// "Where are you going?" At the largest text sizes (A8) the title and hint wrap down; the voice
/// dock keeps its size and its 712 line.
struct OnboardingGoalQuestionView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    var body: some View {
        let draft = OnboardingDraft.shared
        FlowScreen {
            OnboardingNav(id: id, progress: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Where are you going?")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                Text("One sentence. It can have parts.")
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                    .padding(.top, Space.s)
            }
            .region(.focalTop)

            OnboardingVoiceDock(micMode: .rings, micLabel: "Say your goal", onKeyboard: {
                draft.answering = false
                model.replace(with: .a4k)
            }, onMic: {
                onboardingStartListening(model: model, draft: draft, answering: false) {
                    model.replace(with: .a4k)
                }
            })
        }
    }
}

// MARK: - A3 · Listening

/// The question greys; words land under it; stops on silence. Also listens for the A4b answer.
struct OnboardingListeningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    @State private var capture = OnboardingVoiceCapture()

    /// Launched straight onto A3 (screenshots): show the board's words, don't start the fakes.
    private var staticBoard: Bool { model.fixture?.id == id }

    var body: some View {
        let draft = OnboardingDraft.shared
        let question = draft.answering ? (draft.clarifyingQuestion ?? "Where are you going?") : "Where are you going?"
        let board = staticBoard ? model.fixture?.transcript : nil
        let settled = board?.settled ?? capture.settled
        let pending = board?.pending ?? capture.pending

        FlowScreen {
            NavBar(leading: .back {
                capture.cancel()
                model.replace(with: draft.answering ? .a4b : .a2)
                draft.answering = false
            }, progress: 1)
            .region(.nav)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(question)
                    .compassFont(draft.answering ? .heading : .title)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                ScrollView {
                    LiveTranscript(settled: settled, pending: pending)
                        .onboardingWraps()
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .accessibilityLabel(settled.isEmpty && pending.isEmpty ? "Listening" : settled + " " + pending)
            }
            .region(.focalTop)

            Waveform(levels: capture.levels.isEmpty ? FakeAudioRecorder.designLevels : capture.levels,
                     lit: capture.levels.isEmpty ? 32 : nil)
                .region(.wave)

            OnboardingVoiceDock(micMode: .listening, micLabel: "Stop", onKeyboard: {
                let words = staticBoard ? (board?.text ?? "") : capture.text
                capture.cancel()
                if !words.isEmpty { draft.text = GoalShaper.normalize(words) }
                draft.answering = false
                model.replace(with: .a4k)
            }, onMic: {
                if staticBoard {
                    model.replace(with: draft.accept(captured: board?.text ?? "", byVoice: true))
                } else if capture.isRunning {
                    capture.finish()
                } else {
                    model.replace(with: draft.accept(captured: capture.text, byVoice: true))
                }
            })
        }
        .task {
            guard !staticBoard else { return }
            UIAccessibility.post(notification: .announcement, argument: "Listening")
            let script = draft.answering ? "Run twice a week, sleep by eleven and see friends every Sunday" : Fixtures.goalText
            capture.start(model: model, script: script) { words in
                model.replace(with: draft.accept(captured: words, byVoice: true))
            }
        }
        .onDisappear { capture.cancel() }
    }
}

// MARK: - A4 · Review, A4k · Review editing, A4b · Vague goal

/// Your words become the goal: tap to edit (keyboard up, field stays at 128, Continue on the keyboard),
/// or say it again. A vague goal gets one question, never a block.
struct OnboardingReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    @Bindable private var draft = OnboardingDraft.shared
    @FocusState private var focused: Bool
    @State private var editingRequested = false

    /// Launched straight onto A4k (screenshots): draw the keyboard state without a real keyboard.
    private var boardKeyboard: Bool { id == .a4k && model.fixture?.id == id }
    private var editing: Bool { focused || boardKeyboard || (id == .a4k && editingRequested) }
    private var canContinue: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FlowScreen {
            OnboardingNav(id: id, progress: 1)

            VStack(alignment: .leading, spacing: 0) {
                UnderlineField(prompt: "Where are you going?", text: $draft.text, style: .title,
                               focused: $focused, showsFocus: boardKeyboard)
                    .lineLimit(id == .a4b ? 1...4 : 3...6)
                    .accessibilityLabel("Your goal")
                if id == .a4b, let question = draft.clarifyingQuestion {
                    Text(question)
                        .compassFont(.heading)
                        .onboardingWraps()
                        .padding(.top, Space.l)
                }
            }
            .region(.focalTop)

            if editing {
                PrimaryButton("Continue", action: continueTapped)
                    .opacity(canContinue ? 1 : 0.4)
                    .disabled(!canContinue)
                    .region(.aboveKeyboard)
                if boardKeyboard { OnboardingKeyboardPlaceholder() }
            } else if id == .a4b {
                ButtonDock(primary: "Answer", primaryIcon: .mic, link: "Keep it as is", onPrimary: {
                    onboardingStartListening(model: model, draft: draft, answering: true) { focused = true }
                }, onLink: {
                    draft.keepAsIs()
                    model.go(.a5)
                })
            } else {
                ButtonDock(primary: "Continue", link: "Say it again", onPrimary: continueTapped, onLink: {
                    onboardingStartListening(model: model, draft: draft, answering: false) {
                        model.replace(with: .a4k)
                    }
                })
            }
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: editing)
        .onAppear {
            if id == .a4k, !boardKeyboard {
                editingRequested = true
                focused = true
            }
        }
    }

    private func continueTapped() {
        guard let next = draft.continueFromReview(on: id) else { return }
        focused = false
        if next == .a4b { model.replace(with: .a4b) } else { model.go(next) }
    }
}

// MARK: - A5 · Parts

/// Split and symbols proposed; tap a part to change its words or symbol.
struct OnboardingPartsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced

    @State private var editingPartID: UUID?
    @State private var partTitle = ""
    @State private var partSymbol: PartSymbol = .flag
    @FocusState private var titleFocused: Bool

    var body: some View {
        let draft = OnboardingDraft.shared
        FlowScreen {
            OnboardingNav(id: .a5, progress: 2)

            VStack(alignment: .leading, spacing: 0) {
                Text(GoalShaper.partsTitle(count: draft.parts.count))
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(draft.parts) { part in
                        ListRow(icon: CompassIcon(part.symbol), tile: true, title: part.title, action: { open(part) }) {
                            Icon(.down, size: IconSize.s).foregroundStyle(.ink3)
                        }
                        .accessibilityHint("Change this part")
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                .padding(.top, Space.l)
            }
            .region(.focalTop)

            ButtonDock(primary: "Continue", link: draft.parts.count > 1 ? "Keep it as one part" : nil, onPrimary: {
                if draft.parts.isEmpty { draft.keepAsOnePart() }
                model.go(.a6)
            }, onLink: {
                draft.keepAsOnePart()
                model.go(.a6)
            })
        }
        .compassSheet(isPresented: sheetShown, height: 716, label: "Change this part") {
            partSheet(draft: draft)
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: editingPartID)
    }

    private var sheetShown: Binding<Bool> {
        Binding(get: { editingPartID != nil }, set: { if !$0 { editingPartID = nil } })
    }

    private func open(_ part: GoalPart) {
        partTitle = part.title
        partSymbol = part.symbol
        editingPartID = part.id
    }

    @ViewBuilder
    private func partSheet(draft: OnboardingDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Change this part")
                .compassFont(.body)
                .foregroundStyle(.ink2)
                .padding(.top, Space.s)
            UnderlineField(prompt: "Part of your goal", text: $partTitle, style: .heading, axis: .horizontal, focused: $titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .accessibilityLabel("Part name")
                .padding(.top, Space.m)
            Text("Symbol")
                .compassFont(.caption)
                .foregroundStyle(.ink3)
                .padding(.top, Space.l)
            HStack(spacing: Space.xs) {
                ForEach(PartSymbol.allCases, id: \.self) { symbol in
                    Button { partSymbol = symbol } label: {
                        Tile(icon: CompassIcon(symbol))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                    .strokeBorder(symbol == partSymbol ? Color.ink : Color.clear, lineWidth: 2)
                            )
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Self.symbolName(symbol))
                    .accessibilityAddTraits(symbol == partSymbol ? .isSelected : [])
                }
            }
            .padding(.top, Space.xs)
            Spacer(minLength: Space.m)
            PrimaryButton("Save") {
                if let id = editingPartID { draft.updatePart(id, title: partTitle, symbol: partSymbol) }
                titleFocused = false
                editingPartID = nil
            }
            Group {
                if draft.parts.count > 1 {
                    LinkButton("Remove this part") {
                        if let id = editingPartID { draft.removePart(id) }
                        titleFocused = false
                        editingPartID = nil
                    }
                } else {
                    LinkButton("Cancel") {
                        titleFocused = false
                        editingPartID = nil
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 52)
        }
    }

    static func symbolName(_ symbol: PartSymbol) -> String {
        switch symbol {
        case .wealth: "Wealth"
        case .strength: "Strength"
        case .friends: "Friends"
        case .flag: "Flag"
        case .sun: "Sun"
        case .moon: "Moon"
        }
    }
}

// MARK: - A6 · Rhythm and notifications

/// Times and the permission in one step. The system prompt appears on "Allow notifications".
struct OnboardingRhythmView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = OnboardingDraft.shared
        FlowScreen {
            OnboardingNav(id: .a6, progress: 3)

            VStack(alignment: .leading, spacing: 0) {
                Text("Two moments a day.")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                Text("One notification at each. Nothing else.")
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                    .padding(.top, Space.s)
                VStack(spacing: 0) {
                    row(icon: .sun, title: "Center", time: draft.rhythm.morning,
                        earlier: { draft.rhythm = draft.rhythm.movingMorning(by: -1) },
                        later: { draft.rhythm = draft.rhythm.movingMorning(by: 1) })
                    row(icon: .moon, title: "Look back", time: draft.rhythm.evening,
                        earlier: { draft.rhythm = draft.rhythm.movingEvening(by: -1) },
                        later: { draft.rhythm = draft.rhythm.movingEvening(by: 1) })
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                .padding(.top, Space.l)
            }
            .region(.focalTop)

            ButtonDock(primary: "Allow notifications", link: "Not now", onPrimary: {
                Task { @MainActor in
                    draft.notificationsEnabled = await model.onboardingRequestNotifications()
                    model.go(.a7)
                }
            }, onLink: {
                draft.notificationsEnabled = false
                model.go(.a7)
            })
        }
    }

    private func row(icon: CompassIcon, title: String, time: TimeOfDay, earlier: @escaping () -> Void, later: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s) {
            Icon(icon).foregroundStyle(.ink)
            Text(title)
                .compassFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(time.description)
                .font(.custom(CompassType.micro.fontName(.medium), fixedSize: 28))
                .monospacedDigit()
                .accessibilityLabel("\(title) at \(time.description)")
            IconButton(.minus, label: "\(title) earlier", action: earlier)
            IconButton(.plus, label: "\(title) later", action: later)
        }
        .frame(minHeight: 72)
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

// MARK: - A7 · Privacy

/// What stays on the phone; one switch for cloud help. Start saves the goal and lands by the clock.
struct OnboardingPrivacyView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var draft = OnboardingDraft.shared

    var body: some View {
        FlowScreen {
            OnboardingNav(id: .a7, progress: 4)

            VStack(alignment: .leading, spacing: 0) {
                Text("Your words stay yours.")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Space.m) {
                    line(.lock) { Text("Speech becomes text on this phone.").compassFont(.body).onboardingWraps() }
                    HStack(alignment: .top, spacing: Space.s) {
                        Icon(.cloud).foregroundStyle(.ink)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Summaries and step ideas").compassFont(.body).onboardingWraps()
                            Text("A private cloud model reads your notes, never trains on them. Off means plain transcripts, no ideas.")
                                .compassFont(.caption)
                                .foregroundStyle(.ink3)
                                .onboardingWraps()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        CompassSwitch(label: "Cloud help", isOn: $draft.cloudAssist)
                            .padding(.top, -6)
                    }
                    line(.sync) { Text("History syncs through your iCloud.").compassFont(.body).onboardingWraps() }
                }
                .padding(.top, Space.l)
            }
            .region(.focalTop)

            ButtonDock(primary: "Start", onPrimary: { model.onboardingFinish(draft) })
        }
    }

    private func line<Content: View>(_ icon: CompassIcon, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Icon(icon).foregroundStyle(.ink)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
