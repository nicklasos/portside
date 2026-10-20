import SwiftUI

/// Host, port and command for one process, plus the live URL preview line.
struct ProcessEditorView: View {
    @Binding var process: ProcessConfig
    let site: Site
    let isMain: Bool
    let issues: [ValidationIssue]
    var envPort: DetectedPort? = nil
    var detectedCommand: DetectedCommand? = nil
    @Environment(PortsideController.self) private var controller
    @State private var showsAdvanced = false

    private static let labelWidth: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fields
            VStack(alignment: .leading, spacing: 4) {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    Toggle("Preserve Host header", isOn: $process.preserveHost)
                        .help("Pass the browser's Host (\(controller.domain(for: site, process: process) ?? "the domain")) to the server instead of \(process.upstream). Turn on for backends that route by host.")
                        .padding(.top, 2)
                }
                .font(.system(size: 11))
            }
            .padding(.leading, Self.labelWidth + 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                label("Label")
                HStack(spacing: 8) {
                    TextField("", text: $process.label, prompt: Text(isMain ? "Frontend" : "API"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    if !isMain {
                        Text("Subdomain").fixedSize()
                        TextField("", text: subdomain, prompt: Text("api"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text(".\(site.name.isEmpty ? "site" : site.name)\(controller.settings.domainSuffix.display)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
            if let message = message(for: .subdomain(process.id)) {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); message }
            }
            GridRow {
                label("Command")
                TextField("", text: $process.command, prompt: Text("e.g. npm run dev"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            if isMain, process.isStatic || detectedCommand != nil {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); commandHint }
            }
            GridRow {
                label("Host")
                HStack(spacing: 8) {
                    TextField("", text: $process.host, prompt: Text("localhost"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("Port").fixedSize()
                    TextField("", text: port, prompt: Text("5474"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer(minLength: 0)
                }
            }
            if let message = message(for: .port(process.id)) {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); message }
            }
            if isMain, let envPort {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); envPortHint(envPort) }
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
        }
    }

    private func envPortHint(_ detected: DetectedPort) -> some View {
        HStack(spacing: 4) {
            if process.port == detected.port {
                Text("Port \(String(detected.port)) from \(detected.file) (\(detected.key))")
            } else {
                Text("\(detected.file) says \(String(detected.port)) (\(detected.key)) ·")
                Button("Use") { process.port = detected.port }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var commandHint: some View {
        HStack(spacing: 4) {
            if process.isStatic {
                Text("Static site: Portside serves this folder's files directly. Add a command to run a dev server.")
                if let detectedCommand {
                    Button("Use \(detectedCommand.command)") { process.command = detectedCommand.command }
                        .buttonStyle(.link)
                }
            } else if let detectedCommand {
                if process.command == detectedCommand.command {
                    Text("from \(detectedCommand.source)")
                } else {
                    Text("\(detectedCommand.source) says \(detectedCommand.command) ·")
                    Button("Use") { process.command = detectedCommand.command }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: Self.labelWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func message(for field: SiteField) -> FieldMessage? {
        issues.first { $0.field == field }.map { FieldMessage(text: $0.message, isError: $0.severity == .error) }
    }

    private var preview: String {
        let upstream = "http://\(process.host.isEmpty ? "localhost" : process.host):\(process.port)"
        guard let domain = controller.domain(for: site, process: process), !site.name.isEmpty else {
            return isMain ? "→ add a name to get a \(controller.settings.domainSuffix.display) domain" : "→ no domain (internal only) · \(upstream)"
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
