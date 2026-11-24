import AppKit
import SwiftUI

/// Reports whether the window hosting this view is visible on screen.
///
/// SwiftUI keeps a MenuBarExtra panel's content alive after the panel closes and keeps
/// re-rendering it on every data change. Views use this to stop observing live data
/// while nobody can see them.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let view = VisibilityTrackingView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: VisibilityTrackingView, context: Context) {
        view.onChange = { isVisible = $0 }
    }
}

final class VisibilityTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { report(false); return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(nil) }
        }
        report(nil)
    }

    private func report(_ value: Bool?) {
        let visible = value ?? (window?.occlusionState.contains(.visible) ?? false)
        guard visible != lastReported else { return }
        lastReported = visible
        // Defer so SwiftUI state is not changed during a view update.
        DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
    }
}
