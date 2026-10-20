#if DEBUG
import AppKit
import SwiftUI

/// `-PortsideOpenWindow logs:<site>|editor:<site>|editor:new|settings|resolver|popover` opens a
/// surface at launch, so screenshots can be taken without clicking through the menu bar.
/// `-PortsideSnapshot <file.png>` then renders that window to a PNG from inside the app, which
/// needs no screen-recording permission, and writes the menu bar glyph variants next to it.
@MainActor
enum DebugLaunch {
    private static var done = false

    static func openRequestedWindow(_ controller: PortsideController) {
        guard !done, let request = UserDefaults.standard.string(forKey: "PortsideOpenWindow") else { return }
        done = true
        let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
        let site = parts.count > 1 ? controller.store.sites.first { $0.name == parts[1] } : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            switch parts[0] {
            case "logs": if let site { controller.show(.logs(site.id)) }
            case "editor": controller.show(.editor(site.map { .edit($0.id) } ?? .new))
            case "settings": controller.show(.settings)
            case "resolver": controller.show(.resolverSetup)
            case "popover": clickStatusItem()
            case "popover-window": showPopoverContentInWindow(controller)
            default: NSLog("Portside: unknown PortsideOpenWindow \(request)")
            }
        }
        if let path = UserDefaults.standard.string(forKey: "PortsideSnapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                snapshotFrontWindow(to: URL(fileURLWithPath: path))
                snapshotGlyphs(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("menubar-glyphs.png"))
            }
        }
    }

    private static func snapshotFrontWindow(to url: URL) {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && !$0.className.contains("StatusBar") }) ?? NSApp.windows.first(where: { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("Portside: no window to snapshot among \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible)" })")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let flattened = NSImage(size: view.bounds.size, flipped: false) { rect in
            window.backgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            image.draw(in: rect)
            return true
        }
        write(flattened, scale: window.backingScaleFactor, to: url)
        NSLog("Portside: wrote \(url.path) from \(window.className) \(window.title)")
    }

    private static func snapshotGlyphs(to url: URL) {
        let statuses = [MenuBarStatus(isActive: false, needsAttention: false), MenuBarStatus(isActive: true, needsAttention: false), MenuBarStatus(isActive: true, needsAttention: true)]
        let cell = NSSize(width: 44, height: 30)
        let canvas = NSImage(size: NSSize(width: cell.width * 3, height: cell.height * 2), flipped: true) { _ in
            for (row, dark) in [false, true].enumerated() {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                appearance.performAsCurrentDrawingAppearance {
                    (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: 0, y: CGFloat(row) * cell.height, width: cell.width * 3, height: cell.height).fill()
                    for (col, status) in statuses.enumerated() {
                        let icon = MenuBarIcon.image(for: status, darkMenuBar: dark)
                        let origin = NSPoint(x: CGFloat(col) * cell.width + (cell.width - icon.size.width) / 2, y: CGFloat(row) * cell.height + (cell.height - icon.size.height) / 2)
                        let rect = NSRect(origin: origin, size: icon.size)
                        if icon.isTemplate {
                            let tinted = NSImage(size: icon.size, flipped: false) { r in
                                icon.draw(in: r)
                                NSColor.labelColor.set()
                                r.fill(using: .sourceAtop)
                                return true
                            }
                            tinted.draw(in: rect)
                        } else {
                            icon.draw(in: rect)
                        }
                    }
                }
            }
            return true
        }
        write(canvas, scale: 4, to: url)
    }

    private static func write(_ image: NSImage, scale: CGFloat, to url: URL) {
        let pixels = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The popover's content in an ordinary window, which in-app snapshots render faithfully;
    /// the real popover's vibrancy layers do not survive `cacheDisplay`.
    private static func showPopoverContentInWindow(_ controller: PortsideController) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MenuBarView().environment(controller)))
        window.styleMask = [.borderless]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func clickStatusItem() {
        func find(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        let buttons = NSApp.windows.compactMap { $0.contentView.flatMap(find) }
        guard let button = buttons.first else {
            NSLog("Portside: status item button not found among \(NSApp.windows.map(\.className))")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
    }
}
#endif
