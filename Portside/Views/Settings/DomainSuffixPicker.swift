import SwiftUI

/// What the user has selected but not applied yet. Custom text is kept while a preset is selected,
/// so switching back to Custom does not lose it.
struct DomainSuffixDraft: Equatable {
    enum Choice: Hashable {
        case preset(DomainSuffix)
        case custom
    }

    var choice: Choice
    var customText: String

    init(_ suffix: DomainSuffix) {
        choice = suffix.isPreset ? .preset(suffix) : .custom
        customText = suffix.isPreset ? "" : suffix.label
    }

    var result: Result<DomainSuffix, DomainSuffix.Rejection> {
        switch choice {
        case .preset(let suffix): .success(suffix)
        case .custom: DomainSuffix.custom(customText)
        }
    }

    var suffix: DomainSuffix? { try? result.get() }
}

/// Every suffix option with what it costs on this Mac, shared by onboarding and Settings.
struct DomainSuffixPicker: View {
    @Binding var draft: DomainSuffixDraft
    @Environment(PortsideController.self) private var controller
    @State private var checks: [DomainSuffix: SuffixUsability] = [:]
    @FocusState private var customFocused: Bool

    private static let badges: [DomainSuffix: String] = [.localhost: "Recommended", .local: "Not recommended"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(DomainSuffix.presets, id: \.self) { preset in
                option(.preset(preset), title: preset.display, badge: Self.badges[preset]) {
                    lines(for: preset)
                }
            }
            option(.custom, title: "Custom…") {
                TextField("", text: $draft.customText, prompt: Text("wip"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(draft.choice != .custom)
                    .focused($customFocused)
                switch DomainSuffix.custom(draft.customText) {
                case .success(let suffix): lines(for: suffix)
                case .failure(let rejection) where !draft.customText.isEmpty: CheckLineView(line: CheckLine(.failure, rejection.reason))
                case .failure: EmptyView()
                }
            }
            Text(preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 24)
        }
        .onChange(of: draft.choice) { customFocused = draft.choice == .custom }
        .task(id: refreshKey) { await checkPresets() }
        .task(id: draft.customText) { await checkCustom() }
    }

    @ViewBuilder
    private func lines(for suffix: DomainSuffix) -> some View {
        if let usability = checks[suffix] {
            ForEach(Array(usability.lines.enumerated()), id: \.offset) { CheckLineView(line: $0.element) }
        } else {
            CheckLineView(line: suffix.nameCheck)
            Label("Checking how this Mac resolves it…", systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Re-checks after anything that changes the answers: a new suffix, a resolver file, a DNS port.
    private var refreshKey: String {
        "\(controller.settings.domainSuffix.label) \(controller.settings.dnsPort) \(controller.resolverStatus) \(controller.staleResolvers.count)"
    }

    private func checkPresets() async {
        var suffixes = DomainSuffix.presets
        if case .success(let custom) = DomainSuffix.custom(draft.customText) { suffixes.append(custom) }
        let controller = controller
        await withTaskGroup(of: (DomainSuffix, SuffixUsability).self) { group in
            for suffix in suffixes {
                group.addTask { await (suffix, controller.usability(of: suffix)) }
            }
            for await (suffix, usability) in group { checks[suffix] = usability }
        }
    }

    /// Debounced, so typing does not fire a lookup per keystroke.
    private func checkCustom() async {
        guard case .success(let suffix) = DomainSuffix.custom(draft.customText), checks[suffix] == nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        checks[suffix] = await controller.usability(of: suffix)
    }

    private var preview: String {
        guard let suffix = draft.suffix else { return " " }
        return controller.settings.url(forDomain: "blog.\(suffix.label)").absoluteString
    }

    private func option(_ choice: DomainSuffixDraft.Choice, title: String, badge: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        let selected = draft.choice == choice
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                content()
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { draft.choice = choice }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct CheckLineView: View {
    let line: CheckLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityLabel(accessibilityMark)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                }
            }
        }
        .font(.system(size: 11))
    }

    private var symbol: String {
        switch line.mark {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch line.mark {
        case .ok: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    private var accessibilityMark: String {
        switch line.mark {
        case .ok: "OK"
        case .warning: "Warning"
        case .failure: "Problem"
        }
    }
}
