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
                if !message.isEmpty {
                    Text(message)
                        .wwFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
}

