#if DEBUG
import AppKit

/// `-PortsideOpenWindow logs:<site>|editor:<site>|editor:new|settings|resolver|popover` opens a
/// surface at launch, so screenshots can be taken without clicking through the menu bar.
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
            default: NSLog("Portside: unknown PortsideOpenWindow \(request)")
            }
        }
    }

    private static func clickStatusItem() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView?.subviews.first(where: { $0 is NSStatusBarButton }) as? NSStatusBarButton {
                button.performClick(nil)
                return
            }
            if let button = window.contentView as? NSStatusBarButton {
                button.performClick(nil)
                return
            }
        }
        NSLog("Portside: status item button not found")
    }
}
#endif
