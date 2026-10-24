import AppKit
import SwiftUI

/// Placed in the popover's background. Each time the popover opens it brings Portside's other open
/// windows above other apps' windows. A menu bar app has no Dock icon and no ⌘Tab entry, so the
/// menu bar icon is the only way back to a Logs or Site window that fell behind another app.
struct RaiseAppWindows: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RaisingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RaisingView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let popover = window else { return }
            // The popover window becomes key on every open, so this does not rely on SwiftUI
            // re-sending onAppear each time it shows the same content.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: popover, queue: .main) { _ in
                MainActor.assumeIsolated { Self.raise(except: popover) }
            }
            if popover.isKeyWindow { Self.raise(except: popover) }
        }

        private static func raise(except popover: NSWindow) {
            let windows = NSApp.orderedWindows.filter { $0 !== popover && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            // orderedWindows is front to back, so raising back to front keeps their stacking order.
            for window in windows.reversed() { window.orderFrontRegardless() }
        }
    }
}
