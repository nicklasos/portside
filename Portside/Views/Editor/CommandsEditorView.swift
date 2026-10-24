import SwiftUI

/// The site editor's Commands tab: one-off commands the site's … menu runs.
struct CommandsEditorView: View {
    @Binding var commands: [SiteCommand]
    let issues: [ValidationIssue]
    @FocusState private var focusedName: SiteCommand.ID?

    private static let labelWidth: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if commands.isEmpty {
                    Text("No commands yet. Add one to run it from the site's … menu.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let command = SiteCommand(name: "", command: "")
                    commands.append(command)
                    focusedName = command.id
                } label: {
                    Label("Add Command", systemImage: "plus")
                }
                .controlSize(.small)
            }
            ForEach($commands) { $command in
                box($command)
            }
        }
    }

    private func box(_ command: Binding<SiteCommand>) -> some View {
        let id = command.wrappedValue.id
        return VStack(alignment: .trailing, spacing: 2) {
            Button("Remove", role: .destructive) {
                commands.removeAll { $0.id == id }
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                row("Name") {
                    TextField("", text: command.name, prompt: Text("Deploy"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focusedName, equals: id)
                    Spacer(minLength: 0)
                }
                message(for: .commandName(id), in: command.wrappedValue)
                row("Command") {
                    TextField("", text: command.command, prompt: Text("make deploy"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                message(for: .commandLine(id), in: command.wrappedValue)
                row("Folder") {
                    FolderPicker(
                        path: Binding(get: { command.wrappedValue.workingDirectory ?? "" }, set: { command.wrappedValue.workingDirectory = $0.nilIfEmpty }),
                        placeholder: "(inherits site folder)",
                        error: issues.first { $0.field == .commandDirectory(id) }?.message
                    )
                }
                Toggle("Show logs", isOn: command.showsLogs)
                    .help("Open the logs window when the command runs. Off runs it in the background and notifies when it finishes.")
                    .padding(.leading, Self.labelWidth + 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: Self.labelWidth, alignment: .trailing)
            field()
        }
    }

    /// A just-added command stays quiet until it is typed into; the footer still names what blocks Save.
    @ViewBuilder
    private func message(for field: SiteField, in command: SiteCommand) -> some View {
        if !command.name.isEmpty || !command.command.isEmpty, let issue = issues.first(where: { $0.field == field }) {
            FieldMessage(text: issue.message, isError: issue.severity == .error)
                .padding(.leading, Self.labelWidth + 8)
        }
    }
}
