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
        let draft = OnboardingDraft.shared
        FlowScreen {
            NavBar(leading: .back { cancel() }).region(.nav)

            VStack(alignment: .leading, spacing: 0) {
                Text("Restoring from iCloud")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                RestoreProgressBar(value: draft.restoreProgress)
                    .padding(.top, Space.l)
                Text(draft.restoreSummary?.line ?? " ")
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                    .padding(.top, Space.s)
            }
            .region(.focalTop)

            LinkButton("Cancel") { cancel() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
        .onAppear {
            guard !staticBoard, task == nil else { return }
            task = Task { @MainActor in await run(draft: draft) }
        }
        .onDisappear { task?.cancel() }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        model.onboardingBack(from: id)
    }

    private func run(draft: OnboardingDraft) async {
        let backup = model.onboardingBackup
        let routing = RestoreRouting.shared
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
    static let shared = RestoreRouting()

    /// R3's reason. `.empty` is the board's copy.
    var nothingReason: NothingToRestoreReason = .empty
    /// A backup with a goal or history is in the user's iCloud (live app only).
    var backupFound = false
    private var checking = false

    /// A1: look for a backup in the background (it may take a while on a new phone).
    func checkForBackup(_ model: AppModel) {
        guard model.fixture == nil, !checking, !backupFound else { return }
        checking = true
        let backup = model.backupRestorer
        Task { @MainActor in
            if case .available = await backup.availability() { self.backupFound = true }
            self.checking = false
        }
    }

    /// A1 "Begin": restore first when a backup exists; a merge would never let onboarding replace it.
    func begin(_ model: AppModel) {
        if backupFound {
            model.go(.r1)
        } else {
            OnboardingDraft.shared.reset()
            model.go(.a2)
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
        let draft = OnboardingDraft.shared
        let goalText = model.goal?.text ?? draft.restoreSummary?.goalText ?? ""
        let steps = draft.restoreSummary?.steps ?? model.snapshot.movedCount
        FlowScreen {
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome back.")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                if !goalText.isEmpty {
                    Text(goalText)
                        .compassFont(.heading)
                        .foregroundStyle(.ink2)
                        .onboardingWraps()
                        .padding(.top, Space.s)
                }
                Text("\(steps) \(steps == 1 ? "step" : "steps") restored.")
                    .compassFont(.body)
                    .foregroundStyle(.ink3)
                    .onboardingWraps()
                    .padding(.top, Space.s)
            }
            .region(.focalTop)

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
        let reason: NothingToRestoreReason = model.fixture == nil ? RestoreRouting.shared.nothingReason : .empty
        FlowScreen {
            NavBar(leading: .back { model.onboardingBack(from: .r3) }).region(.nav)

            VStack(alignment: .leading, spacing: 0) {
                Text(reason.title)
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                Text(reason.message)
                    .compassFont(.body)
                    .foregroundStyle(.ink2)
                    .onboardingWraps()
                    .padding(.top, Space.s)
            }
            .region(.focalTop)

            ButtonDock(primary: "Start fresh", link: "Try again", onPrimary: {
                OnboardingDraft.shared.reset()
                model.replace(with: .a2)
            }, onLink: {
                model.replace(with: .r1)
            })
        }
    }
}
