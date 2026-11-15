import SwiftUI
import UIKit
import CompassCore

// MARK: - R1 · Restoring

/// From Welcome. Looks for a backup through `BackupRestoring`, shows what's coming back, then R2.
/// Nothing found → R3.
struct RestoreProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionReduced) private var reduced
    let id: ScreenID

    @State private var task: Task<Void, Never>?

    /// Launched straight onto R1 (screenshots): hold the board's 60%.
    private var staticBoard: Bool { model.fixture?.id == id }

    var body: some View {
        let draft = model.onboardingDraft
        FlowScreen {
            NavBar(leading: .back { cancel() }).region(.nav)

            VStack(alignment: .leading, spacing: 0) {
                CompassText("Restoring from iCloud", style: .title)
                    .accessibilityAddTraits(.isHeader)
                RestoreProgressBar(value: draft.restoreProgress)
                    .padding(.top, Space.l)
                CompassText(draft.restoreSummary?.line ?? " ", color: .ink2)
                    .padding(.top, Space.s)
            }
            .scrollingRegion(.custom(top: 128, bottom: 728))

            LinkButton("Cancel") { cancel() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
        .onAppear {
            guard !staticBoard, task == nil else { return }
            // Only after the user chose to restore (S2): otherwise ask on A1 first.
            guard model.restoreRouting.restoreChosen else {
                model.restoreRouting.choosing = true
                model.reset(to: .a1)
                return
            }
            task = Task { @MainActor in await run(draft: draft) }
        }
        .onDisappear { task?.cancel() }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        model.restoreRouting.restoreChosen = false
        model.onboardingBack(from: id)
    }

    private func run(draft: OnboardingDraft) async {
        let backup = model.onboardingBackup
        let routing = model.restoreRouting
        draft.restoreProgress = 0
        draft.restoreSummary = nil
        let animation = Motion.animation(Motion.turnTaking, reduced: reduced)
        // On a new phone every file is still in the cloud: the first 30% of the bar is them downloading.
        let availability = await withTaskCancellationHandler {
            await backup.availability { p in
                Task { @MainActor in
                    withAnimation(animation) { draft.restoreProgress = max(draft.restoreProgress, 0.3 * p) }
                }
            }
        } onCancel: {
            backup.cancel()
        }
        guard case .available(let found) = availability else {
            if case .nothing(let reason) = availability { routing.nothingReason = reason }
            if !Task.isCancelled { model.replace(with: .r3) }
            return
        }
        guard !Task.isCancelled else { return }
        draft.restoreSummary = found
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await backup.restore { p in
                    Task { @MainActor in
                        withAnimation(animation) { draft.restoreProgress = max(draft.restoreProgress, p) }
                    }
                }
            } onCancel: {
                backup.cancel()
            }
            guard !Task.isCancelled else { return }
            model.applyRestoredSnapshot(snapshot)
            routing.backupFound = false
            routing.restoreChosen = false
            UIAccessibility.post(notification: .announcement, argument: "Restored")
            model.replace(with: .r2)
        } catch {
            routing.nothingReason = (error as? RestoreError) == .iCloudUnavailable ? .iCloudUnavailable : .empty
            if !Task.isCancelled { model.replace(with: .r3) }
        }
    }
}

// MARK: - Backup detection (A1) and R3's reason

/// What onboarding knows about the user's iCloud: whether a backup exists (A1 sends "Begin" to R1 then,
/// so a second device restores instead of onboarding over the real goal) and why R1 found nothing (R3).
@MainActor
@Observable
final class RestoreRouting {
    /// R3's reason. `.empty` is the board's copy.
    var nothingReason: NothingToRestoreReason = .empty
    /// A backup with a goal or history is in the user's iCloud (live app only).
    var backupFound = false
    private var checking = false

    /// What the backup holds ("212 steps · 186 memos · 1 goal"), for A1's question.
    var foundSummary: BackupSummary?
    /// A1 is asking "Restore" or "Start a new goal" (once, when there is something to restore).
    var choosing = false
    /// The user chose to restore (A1's question or link, R3's Try again). R1 restores only then.
    var restoreChosen = false

    /// A1: look for a backup in the background (it may take a while on a new phone).
    func checkForBackup(_ model: AppModel) {
        guard model.fixture == nil, !checking, !backupFound else { return }
        checking = true
        let backup = model.backupRestorer
        Task { @MainActor in
            if case .available(let found) = await backup.availability() {
                self.backupFound = true
                self.foundSummary = found
            }
            self.checking = false
        }
    }

    /// A1 "Begin": with a backup in iCloud (or its data already synced in), ask once; otherwise onboard.
    func begin(_ model: AppModel) {
        if backupFound || !model.snapshot.isBlank {
            if foundSummary == nil, !model.snapshot.isBlank { foundSummary = BackupSummary(snapshot: model.snapshot) }
            choosing = true
        } else {
            model.onboardingDraft.reset()
            model.go(.a2)
        }
    }

    /// "Restore" (A1's question or "Restore from iCloud"): R1 brings the backup in.
    func chooseRestore(_ model: AppModel) {
        choosing = false
        restoreChosen = true
        model.go(.r1)
    }

    /// "Start a new goal": onboard; the backup is merged meanwhile and the new goal is set on top of it,
    /// so its goal becomes a past goal and the history stays (`onboardingFinish`, `SyncApply`).
    func chooseNewGoal(_ model: AppModel) {
        choosing = false
        restoreChosen = false
        model.onboardingDraft.reset()
        LiveSync.pullNow()
        model.go(.a2)
    }
}

extension View {
    /// A1's one question when a backup exists: Restore, or Start a new goal (history stays either way).
    func restoreChoiceSheet(_ model: AppModel) -> some View {
        let routing = model.restoreRouting
        return compassSheet(isPresented: Binding(get: { routing.choosing }, set: { routing.choosing = $0 }),
                            height: 376, label: "Restore from iCloud?") {
            ConfirmSheetContent(title: "Restore from iCloud?",
                                message: [routing.foundSummary?.line, "Or start a new goal. Your history stays."]
                                    .compactMap { $0 }.joined(separator: "\n"))
        } actions: {
            PrimaryButton("Restore") { routing.chooseRestore(model) }
            SecondaryButton("Start a new goal") { routing.chooseNewGoal(model) }
        }
    }
}

/// 4pt track (#2A2A2D) with an ink fill (onboarding.html R1).
struct RestoreProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.line)
                RoundedRectangle(cornerRadius: 2).fill(Color.ink)
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Restoring")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - R2 · Restored

/// Your goal and total, then Today (or wherever the clock says).
struct RestoreDoneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.onboardingDraft
        let goalText = model.goal?.text ?? draft.restoreSummary?.goalText ?? ""
        let steps = draft.restoreSummary?.steps ?? model.snapshot.movedCount
        FlowScreen {
            VStack(alignment: .leading, spacing: 0) {
                CompassText("Welcome back.", style: .title)
                    .accessibilityAddTraits(.isHeader)
                if !goalText.isEmpty {
                    CompassText(goalText, style: .heading, color: .ink2)
                        .padding(.top, Space.s)
                }
                CompassText("\(steps) \(steps == 1 ? "step" : "steps") restored.", color: .ink3)
                    .padding(.top, Space.s)
            }
            .scrollingRegion(.custom(top: 128, bottom: 668))

            ButtonDock(primary: "Continue", onPrimary: {
                draft.reset()
                model.goToEntry()
            })
        }
    }
}

// MARK: - R3 · Nothing to restore

/// Plain reason, two ways forward.
struct RestoreNothingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The board's copy when iCloud is simply empty; its own words when iCloud is off or still downloading.
        let reason: NothingToRestoreReason = model.fixture == nil ? model.restoreRouting.nothingReason : .empty
        FlowScreen {
            NavBar(leading: .back { model.onboardingBack(from: .r3) }).region(.nav)

            VStack(alignment: .leading, spacing: 0) {
                CompassText(reason.title, style: .title)
                    .accessibilityAddTraits(.isHeader)
                CompassText(reason.message, color: .ink2)
                    .padding(.top, Space.s)
            }
            .scrollingRegion(.custom(top: 128, bottom: 668))

            ButtonDock(primary: "Start fresh", link: "Try again", onPrimary: {
                model.onboardingDraft.reset()
                model.replace(with: .a2)
            }, onLink: {
                model.restoreRouting.restoreChosen = true
                model.replace(with: .r1)
            })
        }
    }
}
