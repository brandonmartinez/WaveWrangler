import SwiftUI

/// Persistent message bar at the top of a window's content (IA §6). Never time-boxed (ST-05); stays until
/// resolved or dismissed. Heading + body + buttons; the whole bar is one accessibility group.
struct MessageBar: View {
    let heading: String
    let message: String
    let symbolName: String
    let actions: [(String, () -> Void)]
    var identifier = "ww.show.messageBar"

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
                Text(message)
                    .wwFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            Button(action.0, action: action.1)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading)
        .accessibilityIdentifier(identifier)
    }
}
