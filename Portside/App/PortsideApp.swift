import SwiftUI

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var controller: PortsideController { appDelegate.controller }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(controller)
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Site", id: WindowID.editor, for: EditorTarget.self) { $target in
            SiteEditorWindow(target: target ?? .new)
                .environment(controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("Logs", id: WindowID.logs, for: Site.ID.self) { $siteID in
            if let siteID {
                LogsWindow(siteID: siteID)
                    .environment(controller)
            }
        }
        .defaultSize(width: 860, height: 520)

        Window("Choose Your Local Domain", id: WindowID.onboarding) {
            OnboardingView()
                .environment(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Set Up Domains", id: WindowID.resolverSetup) {
            ResolverSetupView()
                .environment(controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(controller)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Site…") { controller.show(.editor(.new)) }
                    .keyboardShortcut("n")
            }
        }
    }
}
