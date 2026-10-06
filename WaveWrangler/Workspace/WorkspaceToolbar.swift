import SwiftUI
import WWOrganizer

/// Destination control (IA §4.2). Segments are separate accessibility elements with stable identifiers
/// so later destinations are focusable and announce "Not available in this version" (IA-12). Selecting
/// one never moves keyboard focus (IA-13).
struct DestinationControl: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShowDestination.allCases) { destination in
                let selected = state.destination == destination
                Button {
                    state.select(destination)
                } label: {
                    HStack(spacing: 4) {
                        Text(destination.title)
                        if !destination.isAvailableInThisVersion {
                            Image(systemName: "lock.fill")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
                        }
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(destination.title) (⌘\(destination.shortcutDigit)). \(destination.helpText)")
                .accessibilityLabel(destination.title)
                .accessibilityValue(destination.unavailableValue ?? "")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityHint("Destination \(ShowDestination.allCases.firstIndex(of: destination)! + 1) of \(ShowDestination.allCases.count)")
                .accessibilityIdentifier("ww.show.destination.\(destination.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
        .accessibilityValue(state.destination.title)
        .accessibilityIdentifier("ww.show.destination")
    }
}

/// Toolbar save-status item (states §2): symbol + short text; opens a popover with details and actions.
/// Never says "Saved" unless the status model reports coherent publication (D1).
struct SaveStatusItem: View {
    @Bindable var state: ShowWindowState
    @FocusState private var focused: Bool

    var body: some View {
        let presentation = state.presentation
        Button {
            state.saveStatusPopoverShown.toggle()
        } label: {
            HStack(spacing: 4) {
                if let symbol = presentation.symbolName {
                    Image(systemName: symbol)
                        .foregroundStyle(tint(presentation.tint))
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(presentation.itemText)
                    .lineLimit(1)
            }
        }
        .help(presentation.popoverText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityIdentifier("ww.show.saveStatus")
        .focused($focused)
        .onChange(of: state.saveStatusFocusRequest) { _, _ in focused = true }
        .popover(isPresented: $state.saveStatusPopoverShown, arrowEdge: .bottom) {
            SaveStatusPopover(state: state, presentation: presentation)
                .wwAppEnvironment()
        }
    }

    private func tint(_ tint: StatusTint) -> Color {
        switch tint {
        case .none: .secondary
        case .attention: .orange
        case .failed: .red
        }
    }
}

private struct SaveStatusPopover: View {
    let state: ShowWindowState
    let presentation: SaveStatusPresentation
    @FocusState private var focusedAction: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.itemText)
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.popoverText)
                .wwFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
            if !presentation.actions.isEmpty {
                HStack {
                    ForEach(Array(presentation.actions.enumerated()), id: \.element) { index, action in
                        Button(action.rawValue) {
                            state.saveStatusPopoverShown = false
                            state.perform(action)
                        }
                        .focused($focusedAction, equals: index)
                    }
                }
            }
        }
        .padding(14)
        .accessibilityIdentifier("ww.show.saveStatus.popover")
        // The popover itself (AppKit's frame around this content) needs a description too (A11Y audit, #157).
        .background(PopoverAccessibilityLabel(label: "Save status details"))
        .onAppear { focusedAction = presentation.actions.isEmpty ? nil : 0 }
    }
}

/// Gives the AppKit popover hosting this SwiftUI content an accessibility description: SwiftUI's `.popover` has no
/// API for it, and VoiceOver and the accessibility audit otherwise see an undescribed popover.
private struct PopoverAccessibilityLabel: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> NSView { LabelView(label: label) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class LabelView: NSView {
        let label: String

        init(label: String) {
            self.label = label
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.setAccessibilityLabel(label)
            // The popover element VoiceOver reports is the window's frame view.
            window.contentView?.superview?.setAccessibilityLabel(label)
        }
    }
}
