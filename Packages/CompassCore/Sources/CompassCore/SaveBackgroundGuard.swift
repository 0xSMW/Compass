import Foundation

/// Holds one background task while the save queue has work and the app is not active, so a write queued
/// while the app is in the background (an evening summary or transcript arriving, a sync pull, a
/// notification action) is not suspended halfway, and neither is one in progress when the app leaves.
///
/// - **Begin:** when the queue goes from idle to busy (`SaveQueue.setActivity`) or the app enters the
///   background (`check()`), if the queue has work and the app is not active. Never while it is active.
/// - **One at a time:** nothing more begins while a task is held, however much is queued.
/// - **End:** when the queue reports it went idle and still is idle on the main actor (work queued in the
///   meantime is waited for: it reports idle again when done), or when iOS's time runs out (the expiration
///   handler). Each task is ended exactly once; a call for a task already ended does nothing.
///
/// The app passes UIKit's `beginBackgroundTask` / `endBackgroundTask` (`SystemServices`); tests pass fakes.
@MainActor
public final class SaveBackgroundGuard {
    /// Begins a task and returns its identifier, or nil if iOS gave none. `expired` must be called if iOS's
    /// time runs out (UIKit's expiration handler); it ends the task.
    public typealias Begin = @MainActor (_ expired: @escaping @MainActor @Sendable () -> Void) -> Int?
    public typealias End = @MainActor (_ id: Int) -> Void

    private let queue: SaveQueue
    private let isActive: @MainActor () -> Bool
    private let begin: Begin
    private let end: End
    /// The task held now, and which turn it belongs to (an expiration for an earlier turn is ignored).
    private var held: (turn: UInt64, id: Int)?
    private var turns: UInt64 = 0
    /// Set while `begin` runs, so an expiration handler called from inside it is not lost.
    private var beginning: (turn: UInt64, expired: Bool)?

    /// Starts watching `queue` (replacing any earlier `setActivity` observer).
    public init(queue: SaveQueue, isActive: @escaping @MainActor () -> Bool, begin: @escaping Begin, end: @escaping End) {
        self.queue = queue
        self.isActive = isActive
        self.begin = begin
        self.end = end
        queue.setActivity { [weak self] busy in
            // Busy is reported on the queuing thread (the main actor, in the app); idle on the save worker.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.queueChanged(busy: busy) }
            } else {
                Task { @MainActor [weak self] in self?.queueChanged(busy: busy) }
            }
        }
    }

    /// A task is held now.
    public var isHolding: Bool { held != nil }

    /// Begin a task if the queue has work, the app is not active and none is held: when the queue becomes
    /// busy, and when the app enters the background.
    public func check() {
        guard held == nil, beginning == nil, !queue.isIdle, !isActive() else { return }
        turns += 1
        let turn = turns
        beginning = (turn, false)
        let id = begin { [weak self] in self?.expired(turn) }
        let expiredAlready = beginning?.expired ?? false
        beginning = nil
        guard let id else { return }
        // The expiration handler ran before `begin` returned: end the task now rather than hold it.
        if expiredAlready {
            end(id)
            return
        }
        held = (turn, id)
        // The queue may have gone idle while the task began; its report is on its way, but look now.
        if queue.isIdle { finish() }
    }

    private func queueChanged(busy: Bool) {
        if busy {
            check()
        } else if queue.isIdle {
            finish()
        }
        // Reported idle but busy again: that work reports idle in turn when it is done.
    }

    private func expired(_ turn: UInt64) {
        if beginning?.turn == turn { beginning?.expired = true }
        guard held?.turn == turn else { return }
        finish()
    }

    private func finish() {
        guard let task = held else { return }
        held = nil
        end(task.id)
    }
}
