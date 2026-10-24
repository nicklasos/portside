import SwiftUI

/// Explains `/etc/resolver/<suffix>` before the one administrator prompt. Never installs on its own:
/// another tool (Herd, Valet, dnsmasq) may own the suffix, and replacing its file would break it.
struct ResolverSetupView: View {
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content
            if let error = controller.resolverError {
                FieldMessage(text: error, isError: true)
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var suffix: DomainSuffix { controller.settings.domainSuffix }
    private var file: String { ResolverInstaller.resolverFile(for: suffix).path }

    private var title: String {
        switch controller.resolverStatus {
        case .installed: "\(suffix.display) domains are set up"
        case .missing: "Set up \(suffix.display) domains"
        case .mismatched: "Another tool handles \(suffix.display)"
        }
    }

    @ViewBuilder
    private var content: some View {
        let port = controller.settings.dnsPort
        switch controller.resolverStatus {
        case .installed:
            Text("macOS sends every `\(suffix.display)` lookup to Portside on 127.0.0.1:\(port).")
            EndToEndRow()
        case .missing:
            Text("Portside answers `*\(suffix.display)` names itself, on 127.0.0.1:\(port). For macOS to ask it, Portside writes one small file, `\(file)`:")
            codeBlock(ResolverInstaller.expectedContents(dnsPort: port))
            Text("Writing to `/etc` needs your administrator password once. Nothing else on your Mac changes, and you can remove it later with `sudo rm \(file)`.")
                .foregroundStyle(.secondary)
        case .mismatched:
            Text("`\(file)` already exists and sends `\(suffix.display)` lookups somewhere else. Another tool, for example Laravel Herd, Valet or dnsmasq, probably handles `\(suffix.display)` today. Its current content:")
            codeBlock(controller.resolverContents ?? "")
            Text("Installing routes `\(suffix.display)` to Portside instead (\(ResolverInstaller.expectedContents(dnsPort: port).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))). Sites served by that other tool will stop resolving until you switch back. To keep both, choose `.localhost` in Settings › Network.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch controller.resolverStatus {
        case .installed:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .missing:
            Button("Later") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Install Resolver") { controller.installResolver() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isInstallingResolver)
        case .mismatched:
            Button("Not Now") {
                controller.dismissResolverPrompt()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Use Portside for \(suffix.display)") { controller.installResolver() }
                .disabled(controller.isInstallingResolver)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text.trimmingCharacters(in: .newlines))
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
