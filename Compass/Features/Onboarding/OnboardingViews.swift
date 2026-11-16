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
        NavBar(leading: .back { model.onboardingBack(from: id) }, progress: progress, scalesText: true)
            .region(.nav)
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

/// Asks for mic + speech the first time, then turns to A3; falls back to typing when refused.
@MainActor
private func onboardingStartListening(model: AppModel, draft: OnboardingDraft, answering: Bool, orType: @escaping @MainActor () -> Void) {
    model.onboardingListen(answering: answering, draft: draft, orType: orType)
}

// MARK: - A1 · Welcome

struct OnboardingWelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowScreen {
            OnboardingMark()
                .region(.custom(top: 128, bottom: nil))

            VStack(alignment: .leading, spacing: 0) {
                CompassText("One goal.\nOne step a day.", style: .display)
                    .accessibilityAddTraits(.isHeader)
                CompassText("Say it in the morning. Say what happened at night.", style: .heading, color: .ink2)
                    .padding(.top, Space.m)
            }
            .scrollingRegion(.custom(top: 224, bottom: 668))

            ButtonDock(primary: "Begin", link: "Restore from iCloud", onPrimary: {
                // A backup in iCloud (a second device): ask once, Restore or Start a new goal (S2).
                model.restoreRouting.begin(model)
            }, onLink: {
                model.restoreRouting.chooseRestore(model)
            })
        }
        .restoreChoiceSheet(model)
        .onAppear { model.restoreRouting.checkForBackup(model) }
    }
}

// MARK: - A2 · Goal, A8 · Largest text

/// "Where are you going?" At the largest text sizes (A8) the title and hint wrap down; the voice
/// dock keeps its size and its 712 line.
struct OnboardingGoalQuestionView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    var body: some View {
        let draft = model.onboardingDraft
        FlowScreen {
            OnboardingNav(id: id, progress: 1)

            VStack(alignment: .leading, spacing: 0) {
                CompassText("Where are you going?", style: .title)
                    .accessibilityAddTraits(.isHeader)
                CompassText("One sentence. It can have parts.", color: .ink2)
                    .padding(.top, Space.s)
            }
            .scrollingRegion(.focalTop)

            VoiceDock(micMode: .rings, micLabel: "Say your goal", onKeyboard: {
                draft.answering = false
                model.replace(with: .a4k)
            }, onMic: {
                onboardingStartListening(model: model, draft: draft, answering: false) {
                    model.replace(with: .a4k)
                }
            })
            .region(.dock)
        }
    }
}

// MARK: - A3 · Listening

/// The question greys; words land under it; stops on silence. Also listens for the A4b answer.
/// The take lives in `model.voice` (started on the screen before, so A2 → A3 is turn-taking).
struct OnboardingListeningView: View {
    @Environment(AppModel.self) private var model
    let id: ScreenID

    @State private var finishing = false

    /// Launched straight onto A3 (screenshots): show the board's words; nothing is recording.
    private var staticBoard: Bool { model.fixture?.id == id && !model.voice.isBusy }

    var body: some View {
        let draft = model.onboardingDraft
        let capture = model.voice
        let question = draft.answering ? (draft.clarifyingQuestion ?? "Where are you going?") : "Where are you going?"
        let board = staticBoard ? model.fixture?.transcript : nil
        let settled = board?.settled ?? capture.settled
        let pending = board?.pending ?? capture.pending

        FlowScreen {
            NavBar(leading: .back { leave(to: draft.answering ? .a4b : .a2, keepWords: false) }, progress: 1, scalesText: true)
                .region(.nav)

            VStack(alignment: .leading, spacing: Space.s) {
                CompassText(question, style: draft.answering ? .heading : .title, color: .ink2)
                // Words land right under the question.
                LiveTranscript(settled: settled, pending: pending)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .accessibilityLabel(settled.isEmpty && pending.isEmpty ? "Listening" : settled + " " + pending)
            }
            .region(.focalTop)

            // The board's bars on a still screenshot; the live wave (a level bar with Reduce Motion) otherwise.
            Waveform(levels: staticBoard || capture.levels.isEmpty ? FakeAudioRecorder.designLevels : capture.levels,
                     lit: staticBoard || capture.levels.isEmpty ? 32 : nil, isStatic: staticBoard)
                .region(.wave)

            VoiceDock(micMode: .listening, micLabel: "Stop", onKeyboard: {
                leave(to: .a4k, keepWords: true)
            }, onMic: finish)
            .region(.dock)
        }
        .onAppear {
            capture.onSilence = { finish() }
        }
        .onDisappear {
            capture.onSilence = nil
        }
    }

    /// Stop (tap or silence): the words become the goal (A4), or the answer replaces it; a vague goal
    /// gets one question (A4b). No words: typing.
    private func finish() {
        let draft = model.onboardingDraft
        if staticBoard {
            model.replace(with: draft.accept(captured: model.fixture?.transcript?.text ?? "", byVoice: true))
            return
        }
        guard !finishing else { return }
        finishing = true
        Task { @MainActor in
            let take = await model.voice.stop()
            // The goal keeps its words, not the audio.
            VoiceStorage.shared.delete(take.recording?.fileName)
            if take.transcript.isEmpty {
                draft.answering = false
                model.replace(with: .a4k)
            } else {
                model.replace(with: draft.accept(captured: take.transcript, byVoice: true))
            }
        }
    }

    /// Back or the keyboard: drop the audio; the keyboard keeps the words said so far.
    private func leave(to next: ScreenID, keepWords: Bool) {
        let draft = model.onboardingDraft
        let words = staticBoard ? (model.fixture?.transcript?.text ?? "") : model.voice.text
        if keepWords, !words.isEmpty { draft.text = GoalShaper.normalize(words) }
        draft.answering = false
        Task { @MainActor in await model.voice.discard() }
        model.replace(with: next)
    }
}

// MARK: - A4 · Review, A4k · Review editing, A4b · Vague goal

/// Your words become the goal: tap to edit (keyboard up, field stays at 128, Continue on the keyboard),
/// or say it again. A vague goal gets one question, never a block.
struct OnboardingReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    private var draft: OnboardingDraft { model.onboardingDraft }
    @State private var focused = false
    @State private var editingRequested = false

    /// Launched straight onto A4k (screenshots): draw the keyboard state without a real keyboard.
    private var boardKeyboard: Bool { id == .a4k && model.fixture?.id == id }
    private var editing: Bool { focused || boardKeyboard || (id == .a4k && editingRequested) }
    private var canContinue: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FlowScreen {
            OnboardingNav(id: id, progress: 1)

            VStack(alignment: .leading, spacing: 0) {
                UnderlineField(prompt: "Where are you going?", text: Bindable(draft).text, style: .title,
                               lines: id == .a4b ? 1...4 : 3...6, focused: $focused, showsFocus: boardKeyboard,
                               label: "Your goal", onSubmit: continueTapped)
                if id == .a4b, let question = draft.clarifyingQuestion {
                    CompassText(question, style: .heading)
                        .padding(.top, Space.l)
                }
            }
            .region(.focalTop)

            if editing {
                PrimaryButton("Continue", action: continueTapped)
                    .opacity(canContinue ? 1 : 0.4)
                    .disabled(!canContinue)
                    .region(.aboveKeyboard)
                if boardKeyboard { KeyboardPlaceholder().region(.keyboard) }
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
    @State private var titleFocused = false

    var body: some View {
        let draft = model.onboardingDraft
        FlowScreen {
            OnboardingNav(id: .a5, progress: 2)

            VStack(alignment: .leading, spacing: 0) {
                CompassText(GoalShaper.partsTitle(count: draft.parts.count), style: .title)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(draft.parts) { part in
                        ListRow(icon: CompassIcon(part.symbol), tile: true, title: part.title, action: { open(part) }) {
                            RowChevron(icon: .down)
                        }
                        .accessibilityHint("Change this part")
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                .padding(.top, Space.l)
            }
            .scrollingRegion(.custom(top: 128, bottom: 668))

            ButtonDock(primary: draft.replacing ? "Start" : "Continue", link: draft.parts.count > 1 ? "Keep it as one part" : nil, onPrimary: {
                model.onboardingContinueFromParts(draft)
            }, onLink: {
                draft.keepAsOnePart()
                model.onboardingContinueFromParts(draft)
            })
        }
        .compassSheet(isPresented: sheetShown, height: 476, label: "Change this part", onDismiss: closeSheet) {
            partSheet(draft: draft)
        } actions: {
            PrimaryButton("Save") {
                if let id = editingPartID { draft.updatePart(id, title: partTitle, symbol: partSymbol) }
                closeSheet()
            }
        }
        .animation(Motion.animation(Motion.turnTaking, reduced: reduced), value: editingPartID)
    }

    private var sheetShown: Binding<Bool> {
        Binding(get: { editingPartID != nil }, set: { if !$0 { editingPartID = nil } })
    }

    private func closeSheet() {
        titleFocused = false
        editingPartID = nil
    }

    private func open(_ part: GoalPart) {
        partTitle = part.title
        partSymbol = part.symbol
        editingPartID = part.id
    }

    @ViewBuilder
    private func partSheet(draft: OnboardingDraft) -> some View {
        CompassText("Change this part", color: .ink2)
        UnderlineField(prompt: "Part of your goal", text: $partTitle, style: .heading, lines: 1...1, focused: $titleFocused,
                       label: "Part name", onSubmit: { titleFocused = false })
            .padding(.top, Space.m)
        CompassText("Symbol", style: .caption, color: .ink3)
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
        if draft.parts.count > 1 {
            LinkButton("Remove this part", tone: .destructive, padding: 0) {
                if let id = editingPartID { draft.removePart(id) }
                closeSheet()
            }
            .accessibilityHint("Its words join the goal as a whole")
            .padding(.top, Space.m)
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
        let draft = model.onboardingDraft
        FlowScreen {
            OnboardingNav(id: .a6, progress: 3)

            VStack(alignment: .leading, spacing: 0) {
                CompassText("Two moments a day.", style: .title)
                    .accessibilityAddTraits(.isHeader)
                CompassText("One notification at each. Nothing else.", color: .ink2)
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
            .scrollingRegion(.custom(top: 128, bottom: 668))

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
        TimeStepperRow(icon: icon, title: title, time: time, earlier: earlier, later: later)
    }
}

// MARK: - A7 · Privacy

/// What stays on the phone; one switch for cloud help. Start saves the goal and lands by the clock.
struct OnboardingPrivacyView: View {
    @Environment(AppModel.self) private var model
    private var draft: OnboardingDraft { model.onboardingDraft }

    var body: some View {
        FlowScreen {
            OnboardingNav(id: .a7, progress: 4)

            VStack(alignment: .leading, spacing: 0) {
                CompassText("Your words stay yours.", style: .title)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Space.m) {
                    line(.lock) { CompassText("Speech becomes text on this phone.") }
                    HStack(alignment: .top, spacing: Space.s) {
                        Icon(.cloud).foregroundStyle(.ink)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            CompassText("Summaries and step ideas")
                            CompassText(model.cloudHelpConfigured
                                        ? "A private cloud model reads your notes, never trains on them. Off means plain transcripts, no ideas."
                                        : CloudHelpCopy.notSetUpCaption,
                                        style: .caption, color: .ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        if model.cloudHelpConfigured {
                            CompassSwitch(label: "Cloud help", isOn: Bindable(draft).cloudAssist)
                                .padding(.top, -6)
                        }
                    }
                    line(.sync) { CompassText("History syncs through your iCloud.") }
                }
                .padding(.top, Space.l)
            }
            .scrollingRegion(.custom(top: 128, bottom: 668))

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
