import SwiftUI

/// The site editor's Commands tab: one-off commands the site's … menu runs.
struct CommandsEditorView: View {
    @Binding var commands: [SiteCommand]
    let issues: [ValidationIssue]
    @FocusState private var focusedName: SiteCommand.ID?

    private static let labelWidth = EditorLayout.boxedLabelWidth

    var body: some View {
        if commands.isEmpty {
            ContentUnavailableView {
                Label("No Commands", systemImage: "terminal")
            } description: {
                Text("Add a command to run it from the site's … menu.")
            } actions: {
                Button("Add Command", action: add)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($commands) { $command in
                    box($command)
                }
                Button(action: add) {
                    Label("Add Command", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
    }

    private func add() {
        let command = SiteCommand(name: "", command: "")
        commands.append(command)
        focusedName = command.id
    }

    private func box(_ command: Binding<SiteCommand>) -> some View {
        let id = command.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            row("Name") {
                TextField("", text: command.name, prompt: Text("Deploy"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($focusedName, equals: id)
                Spacer(minLength: 0)
                RemoveButton(help: "Remove Command") {
                    commands.removeAll { $0.id == id }
                }
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
                .padding(.leading, Self.labelWidth + EditorLayout.labelSpacing)
        }
        .editorBox()
    }

    private func row(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: EditorLayout.labelSpacing) {
            Text(title).frame(width: Self.labelWidth, alignment: .trailing)
            field()
        }
    }

    /// A just-added command stays quiet until it is typed into; the footer still names what blocks Save.
    @ViewBuilder
    private func message(for field: SiteField, in command: SiteCommand) -> some View {
        if !command.name.isEmpty || !command.command.isEmpty, let issue = issues.first(where: { $0.field == field }) {
            FieldMessage(text: issue.message, isError: issue.severity == .error)
                .padding(.leading, Self.labelWidth + EditorLayout.labelSpacing)
        }
    }
}
