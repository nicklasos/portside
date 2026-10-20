import AppKit
import SwiftUI

struct FolderPicker: View {
    @Binding var path: String
    var placeholder: String
    var error: String?
    var onChoose: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField("", text: $path, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: choose)
            }
            if let error {
                FieldMessage(text: error, isError: true)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty { panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        onChoose?(url.path)
    }
}

struct FieldMessage: View {
    var text: String
    var isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color.red : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
