import SwiftUI
import UIKit

/// Where the software keyboard is, in screen coordinates. `FlowScreen` hands it to `.aboveKeyboard`
/// through `ScreenMetrics`, so the lifted action rides 16 above the real keys on any phone (a 667pt
/// iPhone SE keyboard starts much higher than the boards' 508 on 844).
@MainActor
@Observable
final class KeyboardFrame {
    /// Shared on purpose: mirrors the one system keyboard of the process (no flow state).
    static let shared = KeyboardFrame()

    /// Top of the visible keyboard in screen points; nil when it is down.
    private(set) var top: CGFloat?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.update(end) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(nil) }
        })
    }

    private func update(_ end: CGRect?) {
        let screenHeight = UIApplication.shared.connectedScenes.lazy
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? .greatestFiniteMagnitude
        guard let end, end.height > 0, end.minY < screenHeight else {
            if top != nil { top = nil }
            return
        }
        if top != end.minY { top = end.minY }
    }
}
