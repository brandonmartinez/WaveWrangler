import SwiftUI
import WWCore
import WWOrganizer

/// Persistent message bar at the top of a window's content (IA §6). Never time-boxed (ST-05); stays until
/// resolved or dismissed. Heading + body + buttons; the whole bar is one accessibility group.
struct MessageBar: View {
    let heading: String
    let message: String
    let symbolName: String
    let actions: [(String, () -> Void)]
    var identifier = "ww.show.messageBar"
    var recoveryChoice: RecoveryChoicePresentation.Choice?
    var recoveryActions: [EditCheckpointAction] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .wwFont(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(heading)
                    .wwFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty {
                    Text(message)
                        .wwFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !actions.isEmpty {
                    actionGrid
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        // The bar never raises its container's minimum height. Its vertically fixed-size text, asked for a minimum
        // at zero width (as the hosting controller does to size the window), wraps per character and reports
        // thousands of points, which pushed the whole show window's content off-screen. Laid out at the real
        // width it still gets its full ideal height.
        .frame(minHeight: 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading)
        .accessibilityIdentifier(identifier)
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 220), alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                actionButton(index: index, action: action)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading) actions")
        .accessibilityValue("\(actions.count) actions")
        .accessibilityIdentifier("\(identifier).actions")
    }

    private func actionButton(index: Int, action: (String, () -> Void)) -> some View {
        let hotkey = shortcut(for: index, choice: recoveryChoice)
        let title = hotkey.map { "\($0.label) \(action.0)" } ?? action.0
        return Button(title, action: action.1)
            .fixedSize(horizontal: false, vertical: true)
            .keyboardShortcut(hotkey?.key, modifiers: hotkey?.modifiers ?? .command)
    }

    private func shortcut(
        for index: Int, choice: RecoveryChoicePresentation.Choice?
    ) -> (key: KeyEquivalent, modifiers: EventModifiers, label: String)? {
        guard let choice, recoveryActions.indices.contains(index) else { return nil }
        switch recoveryActions[index] {
        case .openAsCopy, .showInFinder:
            guard let digit = choice.shortcut.last else { return nil }
            return (KeyEquivalent(digit), .command, choice.shortcut)
        case .restore: return ("r", [.command, .shift], "⇧⌘R")
        case .discard: return ("d", [.command, .shift], "⇧⌘D")
        case .checkAgain: return ("k", [.command, .shift], "⇧⌘K")
        case .dismiss: return ("h", [.command, .shift], "⇧⌘H")
        case .previous: return ("[", .command, "⌘[")
        case .next: return ("]", .command, "⌘]")
        }
    }
}
