import AppKit
import SwiftUI

/// The status item glyph. Without a badge it is the template asset, which macOS tints. With the red
/// badge the image cannot be a template (that would tint the badge too), so the glyph is drawn in
/// the menu bar's foreground color for the given appearance and the badge on top.
enum MenuBarIcon {
    static func image(for status: MenuBarStatus, darkMenuBar: Bool) -> NSImage {
        let glyph = NSImage(named: status.isActive ? "MenuBarActive" : "MenuBarIdle")!
        guard status.needsAttention else {
            glyph.isTemplate = true
            return glyph
        }
        let size = glyph.size
        let badged = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            (darkMenuBar ? NSColor.white : NSColor.black).withAlphaComponent(0.85).set()
            rect.fill(using: .sourceAtop)
            let d: CGFloat = 5
            let dot = NSRect(x: rect.maxX - d - 0.5, y: rect.maxY - d - 0.5, width: d, height: d)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = false
        return badged
    }
}

struct MenuBarLabel: View {
    @Environment(PortsideController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: controller.menuBarStatus, darkMenuBar: colorScheme == .dark))
            .accessibilityLabel("Portside")
            .onAppear(perform: installRouter)
    }

    private func installRouter() {
        controller.windowRouter = { [openWindow, openSettings] window in
            switch window {
            case .editor(let target): openWindow(id: WindowID.editor, value: target)
            case .logs(let site, _): openWindow(id: WindowID.logs, value: site)
            case .onboarding: openWindow(id: WindowID.onboarding)
            case .resolverSetup: openWindow(id: WindowID.resolverSetup)
            case .settings: openSettings()
            }
        }
        #if DEBUG
        DebugLaunch.openRequestedWindow(controller)
        #endif
    }
}

enum WindowID {
    static let editor = "editor"
    static let logs = "logs"
    static let resolverSetup = "resolver-setup"
    static let onboarding = "onboarding"
}
