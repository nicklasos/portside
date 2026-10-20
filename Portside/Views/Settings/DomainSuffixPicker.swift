import SwiftUI

/// What the user has selected but not applied yet. Custom text is kept while a preset is selected,
/// so switching back to Custom does not lose it.
struct DomainSuffixDraft: Equatable {
    enum Choice: Hashable { case localhost, test, custom }

    var choice: Choice
    var customText: String

    init(_ suffix: DomainSuffix) {
        switch suffix {
        case .localhost: choice = .localhost
        case .test: choice = .test
        default: choice = .custom
        }
        customText = suffix.isPreset ? "" : suffix.label
    }

    var result: Result<DomainSuffix, DomainSuffix.Rejection> {
        switch choice {
        case .localhost: .success(.localhost)
        case .test: .success(.test)
        case .custom: DomainSuffix.custom(customText)
        }
    }

    var suffix: DomainSuffix? { try? result.get() }
}

/// The three suffix options with what each one costs on this Mac, shared by onboarding and Settings.
struct DomainSuffixPicker: View {
    @Binding var draft: DomainSuffixDraft
    @Environment(PortsideController.self) private var controller
    @State private var localhostResolution: ResolutionStrategy?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            option(.localhost, title: ".localhost", badge: "Recommended") {
                detail(localhostResolution == .portsideDNS
                    ? "Works with the built-in proxy, but this Mac does not resolve .localhost names itself. Needs one admin password prompt to install /etc/resolver/localhost."
                    : "Works without setup. No admin password.")
            }
            option(.test, title: ".test") {
                detail("Shorter names. Needs one admin password prompt to install /etc/resolver/test.")
                if controller.resolverStatus(for: .test) == .mismatched {
                    FieldMessage(text: "Another tool (for example Laravel Herd or Valet) already uses .test. Choosing it will take .test over.", isError: false)
                }
            }
            option(.custom, title: "Custom…") {
                TextField("", text: $draft.customText, prompt: Text("loc"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onChange(of: draft.customText) { draft.choice = .custom }
                if draft.choice == .custom {
                    switch draft.result {
                    case .success(let suffix):
                        if let warning = suffix.warning { FieldMessage(text: warning, isError: false) }
                        detail("Usually needs one admin password prompt to install /etc/resolver/\(suffix.label).")
                    case .failure(let rejection):
                        if !draft.customText.isEmpty { FieldMessage(text: rejection.reason, isError: true) }
                    }
                }
            }
            Text(preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 24)
        }
        .task { localhostResolution = await controller.detectResolution(for: .localhost) }
    }

    private var preview: String {
        guard let suffix = draft.suffix else { return " " }
        return controller.settings.url(forDomain: "smartcity.\(suffix.label)").absoluteString
    }

    private func option(_ choice: DomainSuffixDraft.Choice, title: String, badge: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: draft.choice == choice ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(draft.choice == choice ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                content()
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { draft.choice = choice }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(draft.choice == choice ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
