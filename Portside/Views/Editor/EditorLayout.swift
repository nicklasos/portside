import SwiftUI

/// Metrics the site editor's tabs share, so every field label sits on one right-aligned column.
enum EditorLayout {
    static let labelWidth: CGFloat = 80
    static let labelSpacing: CGFloat = 8
    static let boxInset: CGFloat = 12
    /// Labels inside a box are narrower by the box's inset, so their fields line up with the fields outside it.
    static let boxedLabelWidth: CGFloat = labelWidth - boxInset
}

extension View {
    /// The panel around one additional process or command.
    func editorBox() -> some View {
        padding(EditorLayout.boxInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// The borderless remove control at the end of a box's first row.
struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
