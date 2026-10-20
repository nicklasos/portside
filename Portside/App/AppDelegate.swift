import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: PortsideController
    private var signalSources: [DispatchSourceSignal] = []
    private var isTerminating = false

    override init() {
        controller = MainActor.assumeIsolated { PortsideController() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        MainActor.assumeIsolated { controller.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `kill <pid>` and Ctrl-C go through the normal quit path, so dev servers and Caddy never outlive Portside.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // Not a direct call: terminate's .terminateLater wait would block this main-queue block,
            // and with it the @MainActor shutdown task queued behind it.
            source.setEventHandler { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
            source.resume()
            signalSources.append(source)
        }
    }
}
