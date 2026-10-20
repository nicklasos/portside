import SwiftUI

@main
struct PortsideApp: App {
    @State private var store = SiteStore()

    var body: some Scene {
        MenuBarExtra("Portside", systemImage: "circle") {
            MenuBarView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
