import SwiftUI

/// Host, port and command for one process, plus the live URL preview line.
struct ProcessEditorView: View {
    @Binding var process: ProcessConfig
    let site: Site
    let isMain: Bool
    let issues: [ValidationIssue]
    @Environment(PortsideController.self) private var controller
    @State private var showsAdvanced = false

    private static let commandExamples = ["make dev", "npm run dev", "go run .", "air"]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                label("Label")
                HStack(spacing: 8) {
                    TextField("", text: $process.label, prompt: Text(isMain ? "Frontend" : "API"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    if !isMain {
                        Text("Subdomain")
                        TextField("", text: subdomain, prompt: Text("api"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text(".\(site.name.isEmpty ? "site" : site.name).test")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let message = message(for: .subdomain(process.id)) {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); message }
            }
            GridRow {
                label("Command")
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 2.5)) { context in
                        TextField("", text: $process.command, prompt: Text(placeholder(at: context.date)))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    if isMain, process.isStatic {
                        Text("Leave empty to serve the folder as static files")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                label("Host")
                HStack(spacing: 8) {
                    TextField("", text: $process.host, prompt: Text("localhost"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("Port")
                    TextField("", text: port, prompt: Text("5474"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer(minLength: 0)
                }
            }
            if let message = message(for: .port(process.id)) {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); message }
            }
            if !isMain {
                GridRow {
                    label("Folder")
                    FolderPicker(
                        path: workingDirectory,
                        placeholder: "(inherits site folder)",
                        error: issues.first { $0.field == .workingDirectory(process.id) }?.message
                    )
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        Toggle("Preserve Host header", isOn: $process.preserveHost)
                            .help("Pass the browser's Host (\(site.domain(for: process) ?? "the domain")) to the server instead of \(process.upstream). Turn on for backends that route by host.")
                            .padding(.top, 2)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: 70, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func message(for field: SiteField) -> FieldMessage? {
        issues.first { $0.field == field }.map { FieldMessage(text: $0.message, isError: $0.severity == .error) }
    }

    private func placeholder(at date: Date) -> String {
        let i = Int(date.timeIntervalSinceReferenceDate / 2.5) % Self.commandExamples.count
        return Self.commandExamples[i]
    }

    private var preview: String {
        let upstream = "http://\(process.host.isEmpty ? "localhost" : process.host):\(process.port)"
        guard let domain = site.domain(for: process), !site.name.isEmpty else {
            return isMain ? "→ add a name to get a .test domain" : "→ no domain (internal only) · \(upstream)"
        }
        let url = controller.settings.url(forDomain: domain).absoluteString
        if isMain, process.isStatic {
            return "→ \(url)  serves  \(site.folder.isEmpty ? "the site folder" : (site.folder as NSString).abbreviatingWithTildeInPath)"
        }
        return "→ \(url)  ⇄  \(upstream)"
    }

    private var subdomain: Binding<String> {
        Binding(
            get: { process.subdomain ?? "" },
            set: { process.subdomain = SiteValidation.sanitizeLabel($0).nilIfEmpty }
        )
    }

    private var workingDirectory: Binding<String> {
        Binding(
            get: { process.workingDirectory ?? "" },
            set: { process.workingDirectory = $0.nilIfEmpty }
        )
    }

    private var port: Binding<String> {
        Binding(
            get: { process.port == 0 ? "" : String(process.port) },
            set: { process.port = Int($0.filter(\.isNumber).prefix(6)) ?? 0 }
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
