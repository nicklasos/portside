import SwiftUI

struct MenuBarView: View {
    @Environment(SiteStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sites.isEmpty {
                Text("No sites yet. Add one to get started.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(store.sites) { site in
                    VStack(alignment: .leading) {
                        Text(site.name)
                        Text(site.domain).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            Divider()
            Button("Quit Portside") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .padding()
        }
        .frame(width: 340)
    }
}
