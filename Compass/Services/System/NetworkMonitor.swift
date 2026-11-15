import Foundation
import Network

/// Watches reachability with `NWPathMonitor` so work that waited for the network (D6's summary) is
/// retried when the connection comes back, not only on "Try now".
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.compass.network", qos: .utility)
    private var started = false

    /// Last known state. Assumed online until the first path update.
    private(set) var isOnline = true
    /// Called on the main actor when the state flips (true = reconnected).
    var onChange: ((Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        started = false
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
