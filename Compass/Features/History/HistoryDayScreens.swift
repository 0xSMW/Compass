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
                    Text(summaryText(day))
                        .compassFont(.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let part = model.snapshot.goal?.part(reflection?.partID ?? day?.step?.partID)
                        ?? model.snapshot.pastGoals.lazy.compactMap({ $0.part(reflection?.partID ?? day?.step?.partID) }).first {
                        PartChip(part: part)
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
        .onDisappear { playback.stop() }
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
                Text(r.transcript)
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notes = day?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { note in
                        NoteRow(text: note.text, duration: note.duration) {
                            playback.toggle(MemoAudio.fileName(for: note))
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
                    Circle().fill(Color.dim).frame(width: 8, height: 8).frame(width: IconSize.s)
                }
                Text(HistoryFormat.dayTitle(key, calendar: model.calendar)).compassFont(.body)
            }
            .foregroundStyle(.ink)
            if let step = day?.step {
                Text(step.title).compassFont(.body).foregroundStyle(.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if showsIntention, let intention = day?.intention {
                Text("“\(intention.text)”").compassFont(.body).foregroundStyle(.ink2).fixedSize(horizontal: false, vertical: true)
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

/// history.html E2 chip: the part this day counted toward (not a button here).
private struct PartChip: View {
    let part: GoalPart

    var body: some View {
        HStack(spacing: Space.xs) {
            Icon(CompassIcon(part.symbol), size: IconSize.s).foregroundStyle(.ink)
            Text(part.title).compassFont(.caption).foregroundStyle(.ink2)
        }
        .padding(.leading, 12)
        .padding(.trailing, Space.s)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
        .overlay(Capsule().strokeBorder(Color.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Counts toward \(part.title)")
    }
}

// MARK: - E4 · Edit a past day

struct HistoryEditDayView: View {
    @Environment(AppModel.self) private var model
    @State private var summary = ""
    @State private var movedIndex = 0
    @State private var partID: UUID?
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        let key = model.historySelectedDay
        let weekday = HistoryFormat.weekday(key, calendar: model.calendar)

        FlowScreen {
            SubjectLine(text: HistoryFormat.dayTitle(key, calendar: model.calendar))
                .region(.subject)
            NavBar(leading: .quietBack("This week") {}, trailing: .text("Edit", quiet: false) {})
                .region(.nav)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .compassSheet(isPresented: Binding(get: { true }, set: { if !$0 { model.back() } }), height: 596, label: "Edit \(weekday)") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("Edit \(weekday)").compassFont(.heading).accessibilityAddTraits(.isHeader)

                    TextField("", text: $summary, prompt: Text("What happened").foregroundStyle(Color.dim), axis: .vertical)
                        .lineLimit(2...4)
                        .compassFont(.body)
                        .foregroundStyle(.ink)
                        .tint(.ink)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 12)
                        .background(Color.ground, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Color.line2, lineWidth: 1))
                        .accessibilityLabel("Summary")

                    SegmentedPill(options: ["Moved", "Not that day"], selection: $movedIndex)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Did you move?")

                    partRow

                    Button { confirmDelete = true } label: {
                        Text("Delete this day’s entry").compassFont(.body).foregroundStyle(.destructive)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, -12)
                }
                .padding(.top, Space.xs)

                Spacer(minLength: Space.s)

                PrimaryButton("Save") {
                    model.saveHistoryEdit(key, summary: summary, moved: movedIndex == 0, partID: partID)
                    model.back()
                }
                LinkButton("Cancel") { model.back() }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 52)
            }
        }
        .confirmationDialog("Delete \(weekday)’s entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                model.deleteHistoryDay(key)
                HistorySelection.shared.day = nil
                model.back()
                if model.current == .e2 || model.current == .e6 { model.back() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The summary, step, notes and recordings from this day go. This can’t be undone.")
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var partRow: some View {
        let parts = model.goal?.activeParts ?? []
        let part = model.goal?.part(partID)
        Menu {
            ForEach(parts) { p in
                Button { partID = p.id } label: { Label(p.title, systemImage: CompassIcon(p.symbol).sfSymbol) }
            }
            Button("None") { partID = nil }
        } label: {
            HStack(spacing: Space.s) {
                Text("Counts toward").compassFont(.body).foregroundStyle(.ink)
                Spacer(minLength: 0)
                HStack(spacing: Space.xs) {
                    if let part { Icon(CompassIcon(part.symbol), size: IconSize.s) }
                    Text(part?.title ?? "No part").compassFont(.body).lineLimit(1)
                }
                .foregroundStyle(.ink2)
            }
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(Color.line2).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Counts toward \(part?.title ?? "no part")")
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
                    Text("\(HistoryFormat.weekday(key, calendar: model.calendar)) changed on two devices.")
                        .compassFont(.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Both recordings are kept. Pick the summary to show.")
                        .compassFont(.body)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s)

                    VStack(spacing: Space.s) {
                        ForEach(versions, id: \.createdAt) { r in
                            OptionCard(selected: r.createdAt == selected, action: { chosen = r.createdAt }) {
                                HStack(spacing: Space.xs) {
                                    Icon(deviceIcon(r), size: IconSize.s)
                                    Text("\(deviceLabel(r)) · \(HistoryFormat.time(r.createdAt, calendar: model.calendar))")
                                        .compassFont(.caption)
                                }
                                .foregroundStyle(.ink3)
                                Text(r.displayText).compassFont(.body).foregroundStyle(.ink)
                                    .fixedSize(horizontal: false, vertical: true)
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
