import SwiftUI
import CompassCore

// MARK: - E2 · A day / E6 · Largest text

/// A past day in the same frame as a saved evening entry: subject at 128 (✓ date, step, intention),
/// summary at 224, part chip, transcript fading out above 648, player on the 712 line.
struct HistoryDayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dts
    let id: ScreenID
    private var playback: VoicePlayback { .shared }
    /// A note opened from the list: it plays as it opens, and can be edited or deleted.
    @State private var openNoteID: UUID?

    var body: some View {
        let key = model.historySelectedDay
        let day = model.snapshot.day(key)
        let reflection = day?.reflection
        let ax = dts.isAccessibilitySize
        let mark = model.history.mark(for: key, snapshot: model.snapshot, today: model.todayKey)

        FlowScreen {
            VStack(alignment: .leading, spacing: 0) {
                DaySubject(key: key, day: day, mark: mark, showsIntention: !ax)
                    .frame(minHeight: ax ? 0 : 72, alignment: .top)

                VStack(alignment: .leading, spacing: 0) {
                    CompassText(summaryText(day), style: .title)
                        .accessibilityAddTraits(.isHeader)
                    if let part = model.snapshot.goal?.part(reflection?.partID ?? day?.step?.partID)
                        ?? model.snapshot.pastGoals.lazy.compactMap({ $0.part(reflection?.partID ?? day?.step?.partID) }).first {
                        // history.html E2 chip: the part this day counted toward (not a button here).
                        Chip(title: part.title, icon: CompassIcon(part.symbol), iconTint: .ink,
                             accessibilityLabel: "Counts toward \(part.title)")
                            .padding(.top, Space.s)
                    }
                    // The transcript takes whatever is left above 648 and fades out; it never pushes
                    // past the player (overlay content doesn't size the slot).
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) { transcriptAndNotes(day) }
                        .clipped()
                        .padding(.top, Space.m)
                        .mask(LinearGradient(stops: [.init(color: .black, location: ax ? 0.6 : 0.75), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .padding(.top, ax ? 56 : Space.m)
            }
            .region(.custom(top: 128, bottom: 648))

            if let r = reflection, let duration = r.duration {
                Player(duration: duration, isPlaying: playback.isPlaying(r.audioFileName),
                       levels: playback.waveform(for: r.audioFileName) ?? Array(FakeAudioRecorder.designLevels.prefix(20)),
                       showsRedo: false) {
                    playback.toggle(r.audioFileName)
                }
                .region(.player)
            }

            NavBar(
                leading: .quietBack("This week") { model.back() },
                trailing: .text("Edit", quiet: false) { model.go(.e4) },
                scalesText: true
            )
            .region(.nav)
        }
        .overlay {
            if let note = openNote(day) {
                NoteDetailSheet(
                    note: note,
                    onSave: { text in
                        model.editNote(note.id, on: key, text: text)
                        openNoteID = nil
                    },
                    onDelete: {
                        model.deleteNote(note.id, on: key)
                        Feedback.announce("Note deleted")
                        openNoteID = nil
                    },
                    onClose: { openNoteID = nil }
                )
                .id(note.id)
                .transition(.opacity)
            }
        }
        .onDisappear { playback.stop() }
    }

    private func openNote(_ day: Day?) -> Note? {
        guard let openNoteID else { return nil }
        return day?.notes.first { $0.id == openNoteID }
    }

    private func summaryText(_ day: Day?) -> String {
        if let r = day?.reflection {
            let s = r.displayText
            if !s.isEmpty { return s }
            return r.summaryState == .waitingForNetwork ? "Saved as audio." : "Saved."
        }
        if let step = day?.step { return step.title }
        return day?.notes.last?.text ?? "Nothing saved this day."
    }

    @ViewBuilder
    private func transcriptAndNotes(_ day: Day?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let r = day?.reflection, !r.transcript.isEmpty, r.transcript != r.displayText {
                CompassText(r.transcript, color: .ink2)
            }
            if let notes = day?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { note in
                        // Opens the note: a recording plays (`<note id>.m4a`), and it can be edited or deleted.
                        NoteRow(note: note) {
                            openNoteID = note.id
                        }
                    }
                }
            }
        }
    }
}

/// The subject block at 128: "✓ Saturday, 7 Nov" in ink, then the step and the intention in #A1A1A6.
private struct DaySubject: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dts
    let key: DayKey
    let day: Day?
    let mark: DayMark
    var showsIntention: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.xs) {
                if mark == .moved {
                    Icon(.ok, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s)
                } else if mark == .missed {
                    DayMarkView(mark: .missed, size: .week).frame(width: IconSize.s)
                }
                CompassText(HistoryFormat.dayTitle(key, calendar: model.calendar)).lineLimit(1)
            }
            .foregroundStyle(.ink)
            if let step = day?.step {
                CompassText(step.title, color: .ink2)
            }
            if showsIntention, let intention = day?.intention {
                CompassText("“\(intention.text)”", color: .ink2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts: [String] = [HistoryFormat.dayTitle(key, calendar: model.calendar)]
        if mark == .moved { parts.append("moved") }
        if mark == .missed { parts.append("missed") }
        if let t = day?.step?.title { parts.append(t) }
        if showsIntention, let t = day?.intention?.text { parts.append(t) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - E4 · Edit a past day

struct HistoryEditDayView: View {
    @Environment(AppModel.self) private var model
    @State private var summary = ""
    @State private var movedIndex = 0
    @State private var partID: UUID?
    @State private var loaded = false
    /// The sheet's levels: the form, "Counts toward" one level in, and the delete question.
    @State private var level: Level = .form

    enum Level { case form, part, delete }

    var body: some View {
        let key = model.historySelectedDay
        let weekday = HistoryFormat.weekday(key, calendar: model.calendar)
        let parts = model.goal?.activeParts ?? []

        FlowScreen {
            SubjectLine(text: HistoryFormat.dayTitle(key, calendar: model.calendar))
                .region(.subject)
            NavBar(leading: .quietBack("This week") {}, trailing: .text("Edit", quiet: false) {})
                .region(.nav)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .compassSheet(isPresented: Binding(get: { true }, set: { if !$0 { model.back() } }), height: sheetHeight(parts.count),
                      label: level == .delete ? "Delete \(weekday)’s entry?" : "Edit \(weekday)",
                      contentTop: level == .part ? Space.m : Space.l, onDismiss: dismiss) {
            switch level {
            case .form: form(weekday: weekday)
            case .part:
                PartPickerRows(parts: parts, selected: partID, allowsNone: true) { id in
                    partID = id
                    level = .form
                }
            case .delete:
                ConfirmSheetContent(title: "Delete \(weekday)’s entry?",
                                    message: "The summary, step, notes and recordings from this day go. This can’t be undone.")
            }
        } actions: {
            switch level {
            case .form:
                PrimaryButton("Save") {
                    model.saveHistoryEdit(key, summary: summary, moved: movedIndex == 0, partID: partID)
                    model.back()
                }
            case .part:
                EmptyView()
            case .delete:
                PrimaryButton("Delete entry", role: .destructive) {
                    model.deleteHistoryDay(key)
                    HistorySelection.shared.day = nil
                    model.back()
                    if model.current == .e2 || model.current == .e6 { model.back() }
                }
            }
        }
        .onAppear(perform: load)
    }

    /// history.html E4: heading, summary box, Moved / Not that day, Counts toward, Delete; Save on 712.
    @ViewBuilder
    private func form(weekday: String) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            CompassText("Edit \(weekday)", style: .heading).accessibilityAddTraits(.isHeader)

            BoxedField(prompt: "What happened", text: $summary, lines: 2...4, label: "Summary")

            SegmentedPill(options: ["Moved", "Not that day"], selection: $movedIndex)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Did you move?")

            partRow

            LinkButton("Delete this day’s entry", tone: .destructive, padding: 0) { level = .delete }
        }
    }

    private var partRow: some View {
        let part = model.goal?.part(partID)
        return Button { level = .part } label: {
            HStack(spacing: Space.s) {
                CompassText("Counts toward").lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: Space.xs) {
                    if let part { Icon(CompassIcon(part.symbol), size: IconSize.s) }
                    CompassText(part?.title ?? "No part", color: .ink2).lineLimit(1)
                }
                .foregroundStyle(.ink2)
            }
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(Color.line2).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Counts toward \(part?.title ?? "no part")")
        .accessibilityHint("Choose the part this day counted toward")
    }

    private func sheetHeight(_ parts: Int) -> CGFloat {
        switch level {
        case .form: 596
        case .part: 24 + 56 * CGFloat(parts + 1) + 16 + 104
        case .delete: 312
        }
    }

    /// Cancel: one level back inside the sheet, or close it.
    private func dismiss() {
        if level == .form { model.back() } else { level = .form }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let day = model.snapshot.day(model.historySelectedDay)
        summary = day?.reflection?.displayText ?? day?.step?.title ?? ""
        movedIndex = (day?.moved ?? false) ? 0 : 1
        partID = day?.reflection?.partID ?? day?.step?.partID
    }
}

// MARK: - E5 · Two devices, same day

/// Notes and audio already merged; only the summary asks. Both recordings are kept either way.
struct HistoryConflictView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Date?

    var body: some View {
        let key = model.historySelectedDay
        let day = model.snapshot.day(key)
        let versions = day?.reflectionVersions ?? []
        let selected = chosen ?? defaultChoice(versions)

        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CompassText("\(HistoryFormat.weekday(key, calendar: model.calendar)) changed on two devices.", style: .title)
                        .accessibilityAddTraits(.isHeader)
                    CompassText("Both recordings are kept. Pick the summary to show.", color: .ink2)
                        .padding(.top, Space.s)

                    VStack(spacing: Space.s) {
                        ForEach(versions, id: \.createdAt) { r in
                            OptionCard(selected: r.createdAt == selected, action: { chosen = r.createdAt }) {
                                HStack(spacing: Space.xs) {
                                    Icon(deviceIcon(r), size: IconSize.s)
                                    CompassText("\(deviceLabel(r)) · \(HistoryFormat.time(r.createdAt, calendar: model.calendar))",
                                                style: .caption, color: .ink3)
                                }
                                .foregroundStyle(.ink3)
                                CompassText(r.displayText)
                            }
                            .accessibilityLabel("\(deviceLabel(r)), \(HistoryFormat.time(r.createdAt, calendar: model.calendar)): \(r.displayText)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Summary to keep")
                    .padding(.top, Space.l)
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.m)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 668, inset: 0))

            NavBar(leading: .quietBack("This week") { model.back() })
                .region(.nav)

            ButtonDock(primary: "Use this summary", link: "Keep both", onPrimary: {
                if let r = versions.first(where: { $0.createdAt == selected }) { model.resolveConflict(key, keeping: r) }
                model.replace(with: .e2)
            }, onLink: {
                model.resolveConflict(key, keeping: nil)
                model.replace(with: .e2)
            })
        }
    }

    /// The version recorded on this device first (E5 preselects "This iPhone"), else the earliest.
    /// Devices are told apart by the stored device id (`DeviceIdentity`), never by the label text.
    private func defaultChoice(_ versions: [Reflection]) -> Date? {
        model.deviceIdentity.defaultChoice(versions)?.createdAt
    }

    /// "This iPhone" only for a version recorded here; otherwise its device's model ("iPad", "iPhone").
    private func deviceLabel(_ r: Reflection) -> String {
        model.deviceIdentity.label(for: r)
    }

    private func deviceIcon(_ r: Reflection) -> CompassIcon {
        model.deviceIdentity.isTablet(r) ? .tablet : .phone
    }
}
