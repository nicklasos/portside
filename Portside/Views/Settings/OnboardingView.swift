import SwiftUI

/// First launch: pick the suffix every site lives under. A suffix that needs a resolver file
/// continues to the resolver panel, which still waits for an explicit click before any admin prompt.
struct OnboardingView: View {
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DomainSuffixDraft(.localhost)
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose your local domain")
                        .font(.title3.weight(.semibold))
                    Text("Every site gets a name under it. You can change it later in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            DomainSuffixPicker(draft: $draft)
            HStack {
                Spacer()
                Button("Continue", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.suffix == nil || isApplying)
            }
        }
        .padding(22)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draft = DomainSuffixDraft(controller.settings.domainSuffix) }
    }

    private func apply() {
        guard let suffix = draft.suffix else { return }
        isApplying = true
        Task {
            await controller.chooseDomainSuffix(suffix)
            isApplying = false
            dismiss()
            if controller.needsResolverSetup { controller.show(.resolverSetup) }
        }
    }
}
