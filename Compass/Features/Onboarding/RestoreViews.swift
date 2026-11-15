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
        draft.restoreProgress = 0
        draft.restoreSummary = nil
        guard case .available(let found) = await backup.availability() else {
            if !Task.isCancelled { model.replace(with: .r3) }
            return
        }
        guard !Task.isCancelled else { return }
        draft.restoreSummary = found
        let animation = Motion.animation(Motion.turnTaking, reduced: reduced)
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await backup.restore { p in
                    Task { @MainActor in
                        withAnimation(animation) { draft.restoreProgress = p }
                    }
                }
            } onCancel: {
                backup.cancel()
            }
            guard !Task.isCancelled else { return }
            model.onboardingAdopt(snapshot)
            UIAccessibility.post(notification: .announcement, argument: "Restored")
            model.replace(with: .r2)
        } catch {
            if !Task.isCancelled { model.replace(with: .r3) }
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
        FlowScreen {
            NavBar(leading: .back { model.onboardingBack(from: .r3) }).region(.nav)

            VStack(alignment: .leading, spacing: 0) {
                Text("No history found.")
                    .compassFont(.title)
                    .onboardingWraps()
                    .accessibilityAddTraits(.isHeader)
                Text("There’s nothing from Compass in the iCloud account on this iPhone.")
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
