import SwiftUI

/// First launch: pick the suffix every site lives under. A suffix that needs a resolver file
/// continues to the resolver panel, which still waits for an explicit click before any admin prompt.
/// A suffix that works without setup is checked end to end right here.
struct OnboardingView: View {
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DomainSuffixDraft(.localhost)
    @State private var isApplying = false
    @State private var applied: DomainSuffix?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // The window hides its title bar, so this header is the only title.
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                Text("Choose Your Local Domain")
                    .font(.title2.weight(.semibold))
                Text("Every site gets a name under it. You can change it later in Settings.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            DomainSuffixPicker(draft: $draft)
            if applied != nil, applied == draft.suffix {
                EndToEndRow()
            }
            HStack {
                Spacer()
                if applied != nil, applied == draft.suffix {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.suffix == nil || isApplying)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draft = DomainSuffixDraft(controller.settings.domainSuffix) }
    }

    private func apply() {
        guard let suffix = draft.suffix else { return }
        isApplying = true
        Task {
            await controller.chooseDomainSuffix(suffix)
            isApplying = false
            if controller.needsResolverSetup {
                dismiss()
                controller.show(.resolverSetup)
            } else {
                applied = suffix
                await controller.runEndToEndCheck()
            }
        }
    }
}

/// The end-to-end result for the suffix in use, with a button to run it again.
struct EndToEndRow: View {
    @Environment(PortsideController.self) private var controller

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if controller.isCheckingEndToEnd {
                Label("Checking \(ResolverInstaller.selfTestHost(zone: controller.settings.domainSuffix.label))…", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let line = controller.endToEnd {
                CheckLineView(line: line)
            } else {
                Text("Not checked yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Test Now") { Task { await controller.runEndToEndCheck() } }
                .controlSize(.small)
                .disabled(controller.isCheckingEndToEnd || controller.resolution == nil)
        }
    }
}
