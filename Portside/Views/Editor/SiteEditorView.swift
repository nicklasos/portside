import SwiftUI

struct SiteEditorWindow: View {
    let target: EditorTarget
    @Environment(PortsideController.self) private var controller

    var body: some View {
        switch target {
        case .new:
            SiteEditorView(original: nil)
        case .edit(let id):
            if let site = controller.store.site(id: id) {
                SiteEditorView(original: site)
            } else {
                Text("This site no longer exists.")
                    .foregroundStyle(.secondary)
                    .frame(width: 320, height: 120)
            }
        }
    }
}

private enum EditorTab: String {
    case general, commands
}

struct SiteEditorView: View {
    let original: Site?
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Site
    @State private var notice: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var formHeight: CGFloat = 0
    @State private var autofill: FolderAutofill
    @State private var scannedFolder: String
    @State private var envPort: DetectedPort?
    @State private var detectedCommand: DetectedCommand?
    @State private var tab: EditorTab = .general
    @FocusState private var nameFocused: Bool

    private var maxFormHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 120 }

    init(original: Site?) {
        self.original = original
        let defaultPort = 3000
        _draft = State(initialValue: original ?? Site(
            name: "", folder: "",
            main: ProcessConfig(label: "Frontend", command: "", port: defaultPort)
        ))
        _autofill = State(initialValue: original == nil ? .newSite(defaultPort: defaultPort) : FolderAutofill())
        _scannedFolder = State(initialValue: original?.folder ?? "")
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "PortsideEditorTab"), let tab = EditorTab(rawValue: raw) {
            _tab = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        let issues = controller.store.issues(for: draft)
        VStack(alignment: .leading, spacing: 0) {
            // The window grows with the site and only scrolls once the form no longer fits on screen.
            // The form is always in a scroll view: the titlebar draws its separator line only when no
            // scroll view sits under it, so swapping one in for tall forms showed the line on one tab only.
            ScrollView { measuredForm(issues) }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(formHeight, maxFormHeight))
            Divider()
            footer(issues)
        }
        .frame(width: 600)
        // Without this the segmented control above the form takes the first focus when keyboard navigation is on.
        .task { nameFocused = tab == .general }
        .navigationTitle(original == nil ? "New Site" : "\(original!.name) — Edit")
        .task(id: draft.folder) {
            guard draft.folder != scannedFolder else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { scanFolder(draft.folder) }
        }
        #if DEBUG
        .onAppear {
            if original == nil, let path = UserDefaults.standard.string(forKey: "PortsideEditorFolder") {
                draft.folder = path
                scanFolder(path)
            }
        }
        #endif
    }

    private func measuredForm(_ issues: [ValidationIssue]) -> some View {
        form(issues)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: FormHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(FormHeightKey.self) { formHeight = $0 }
    }

    private func form(_ issues: [ValidationIssue]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("", selection: $tab) {
                Text(tabLabel("General", for: .general, issues)).tag(EditorTab.general)
                Text(tabLabel(draft.commands.isEmpty ? "Commands" : "Commands (\(draft.commands.count))", for: .commands, issues)).tag(EditorTab.commands)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            switch tab {
            case .general: generalForm(issues)
            case .commands: CommandsEditorView(commands: $draft.commands, issues: issues)
            }
        }
        .padding(20)
    }

    /// Marks the tab that is not showing when it holds an error that blocks Save.
    private func tabLabel(_ title: String, for target: EditorTab, _ issues: [ValidationIssue]) -> String {
        let hasError = issues.contains { $0.severity == .error && $0.field.isCommand == (target == .commands) }
        return target != tab && hasError && hasEdits ? "\(title) ⚠︎" : title
    }

    private func generalForm(_ issues: [ValidationIssue]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                siteFields(issues)
                Toggle("Start automatically when Portside launches", isOn: $draft.autoStart)
                    .padding(.leading, EditorLayout.labelWidth + EditorLayout.labelSpacing)
            }
            VStack(alignment: .leading, spacing: 12) {
                section("Main process")
                ProcessEditorView(process: $draft.main, site: draft, isMain: true, issues: issues, envPort: envPort, detectedCommand: detectedCommand)
            }
            VStack(alignment: .leading, spacing: 12) {
                section("Additional processes")
                ForEach($draft.extras) { $extra in
                    ProcessEditorView(process: $extra, site: draft, isMain: false, issues: issues, labelWidth: EditorLayout.boxedLabelWidth) {
                        draft.extras.removeAll { $0.id == extra.id }
                    }
                    .editorBox()
                }
                Button {
                    draft.extras.append(newExtra())
                } label: {
                    Label("Add Process", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
    }

    private func siteFields(_ issues: [ValidationIssue]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: EditorLayout.labelSpacing, verticalSpacing: 6) {
            GridRow {
                Text("Name").frame(width: EditorLayout.labelWidth, alignment: .trailing).gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        TextField("", text: name, prompt: Text("blog"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .focused($nameFocused)
                        Text(controller.settings.domainSuffix.display).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            controller.openURL(draft)
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                        .disabled(!SiteValidation.isValidLabel(draft.name) || controller.store.site(id: draft.id) == nil)
                    }
                    if let issue = issues.first(where: { $0.field == .name }), !draft.name.isEmpty || original != nil {
                        FieldMessage(text: issue.message, isError: true)
                    }
                }
            }
            GridRow {
                Text("Folder").frame(width: EditorLayout.labelWidth, alignment: .trailing)
                FolderPicker(
                    path: $draft.folder,
                    placeholder: "~/Projects/blog",
                    error: draft.folder.isEmpty ? nil : issues.first { $0.field == .folder }?.message
                ) { path in
                    scanFolder(path)
                }
            }
        }
    }

    /// Fills the name, main port and main command from a folder that exists, once per folder value.
    private func scanFolder(_ path: String) {
        scannedFolder = path
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            envPort = nil
            detectedCommand = nil
            return
        }
        let folder = URL(fileURLWithPath: expanded, isDirectory: true)
        let detected = EnvPortDetector.detect(in: folder)
        let command = CommandDetector.detect(in: folder)
        autofill = autofill.apply(folder: expanded, detected: detected, command: command, to: &draft)
        envPort = detected
        detectedCommand = command
    }

    private func section(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
    }

    private func footer(_ issues: [ValidationIssue]) -> some View {
        HStack(spacing: 10) {
            if let saveError {
                FieldMessage(text: saveError, isError: true)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if let first = issues.first(where: { $0.severity == .error }), hasEdits {
                Text(first.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(notice == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(issues.contains { $0.severity == .error } || isSaving || !hasEdits)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var hasEdits: Bool {
        draft != (controller.store.site(id: draft.id) ?? original)
            || controller.store.site(id: draft.id) == nil
    }

    private var name: Binding<String> {
        Binding(get: { draft.name }, set: { draft.name = SiteValidation.sanitizeLabel($0) })
    }

    private func newExtra() -> ProcessConfig {
        let used = draft.processes.map(\.port).max() ?? 8000
        let isFirst = draft.extras.isEmpty
        return ProcessConfig(label: isFirst ? "API" : "", command: "", port: min(used + 1, 65535), subdomain: isFirst ? "api" : nil)
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                let wasNew = controller.store.site(id: draft.id) == nil
                let result = try await controller.save(edited: draft)
                if wasNew || result == nil {
                    dismiss()
                } else {
                    notice = result
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct FormHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
