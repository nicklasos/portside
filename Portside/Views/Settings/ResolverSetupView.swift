import SwiftUI

/// Explains `/etc/resolver/test` before the one administrator prompt. Never installs on its own:
/// another tool (Herd, Valet, dnsmasq) may own `.test`, and replacing its file would break it.
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
        .padding(22)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch controller.resolverStatus {
        case .installed: ".test domains are set up"
        case .missing: "Set up .test domains"
        case .mismatched: "Another tool handles .test"
        }
    }

    @ViewBuilder
    private var content: some View {
        let port = controller.settings.dnsPort
        switch controller.resolverStatus {
        case .installed:
            Text("macOS sends every `.test` lookup to Portside on 127.0.0.1:\(port).")
            selfTestLine
        case .missing:
            Text("Portside answers `*.test` names itself, on 127.0.0.1:\(port). For macOS to ask it, Portside writes one small file, `/etc/resolver/test`:")
            codeBlock(ResolverInstaller.expectedContents(dnsPort: port))
            Text("Writing to `/etc` needs your administrator password once. Nothing else on your Mac changes, and you can remove it later with `sudo rm /etc/resolver/test`.")
                .foregroundStyle(.secondary)
        case .mismatched:
            Text("`/etc/resolver/test` already exists and sends `.test` lookups somewhere else. Another tool, for example Laravel Herd, Valet or dnsmasq, probably handles `.test` today. Its current content:")
            codeBlock(controller.resolverContents ?? "")
            Text("Installing routes `.test` to Portside instead (\(ResolverInstaller.expectedContents(dnsPort: port).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))). Sites served by that other tool will stop resolving until you switch back. Portside's sites still work at `localhost` ports either way.")
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
            Button("Install resolver") { controller.installResolver() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isInstallingResolver)
        case .mismatched:
            Button("Not now") {
                controller.dismissResolverPrompt()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Use Portside for .test") { controller.installResolver() }
                .disabled(controller.isInstallingResolver)
        }
    }

    @ViewBuilder
    private var selfTestLine: some View {
        switch controller.resolverSelfTest {
        case true?: Label("Responding: portside-selftest.test resolves through Portside", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Label("Not responding yet. Try again in a few seconds, or Repair from Settings.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case nil: Label("Checking…", systemImage: "clock").foregroundStyle(.secondary)
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
