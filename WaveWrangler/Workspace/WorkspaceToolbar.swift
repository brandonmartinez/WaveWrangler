import SwiftUI
import WWOrganizer

struct WorkspaceInspectorToggles: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        HStack(spacing: 2) {
            Button {
                if state.reviewPresentation.isDetached { state.reviewPresentation.detach() }
                else { state.reviewPanelPresented.toggle() }
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .frame(width: 24, height: 24)
                    .background(state.reviewPanelPresented || state.reviewPresentation.isDetached
                                ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review panel")
            .accessibilityValue(state.reviewPresentation.isDetached
                ? "In separate window" : state.reviewPanelPresented ? "Shown" : "Hidden")
            .accessibilityIdentifier("ww.review.toggle")
            .help(state.reviewPresentation.isDetached
                ? "Show the detached Transcript & Review window"
                : "\(state.reviewPanelPresented ? "Hide" : "Show") the resizable bottom review list")
            Button {
                if state.bottomPanePresented, state.bottomPaneContent == .mixer, !state.mixerPresentation.isDetached {
                    state.bottomPanePresented = false
                } else {
                    state.mixerPresentation.showDocked()
                }
            } label: {
                Image(systemName: "slider.vertical.3").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mixer")
            .accessibilityValue(state.bottomPanePresented && state.bottomPaneContent == .mixer ? "Shown" : "Hidden")
            .accessibilityIdentifier("ww.mixer.toggle")
            .help("Show the production mixer in the bottom pane or focus its separate window")
            ForEach(ShowWindowState.WorkspaceInspector.allCases, id: \.self) { activity in
                let active = state.inspectorPresented && state.workspaceInspector == activity
                Button {
                    state.toggleWorkspaceInspector(activity)
                } label: {
                    Image(systemName: activity.symbol)
                        .frame(width: 24, height: 24)
                        .background(active ? Color.accentColor.opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(activity.rawValue) sidebar")
                .accessibilityValue(active ? "Shown" : "Hidden")
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier("ww.sidebar.\(activity.identifier)")
                .help("\(active ? "Hide" : "Show") \(activity.rawValue) sidebar")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar activities")
    }
}

/// Destination control (IA §4.2). Segments are separate accessibility elements with stable identifiers
/// so later destinations are focusable and announce "Not available in this version" (IA-12). Selecting
/// one never moves keyboard focus (IA-13).
struct DestinationControl: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        HStack(spacing: 8) {
            Button("Workspace", systemImage: "waveform") { state.select(.alignment) }
                .accessibilityAddTraits(state.destination == .alignment ? [.isSelected] : [])
                .accessibilityIdentifier("ww.show.destination.alignment")
            NativeActionMenu(
                label: "Views", symbol: "rectangle.3.group",
                identifier: "ww.show.views", actions: viewActions)
            Button("Export…", systemImage: "square.and.arrow.up") { state.select(.export) }
                .help("Export is not available yet. This opens the availability explanation; nothing is exported.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace and alternative views")
        .accessibilityValue(state.destination.title)
        .accessibilityIdentifier("ww.show.destination")
    }

    private var viewActions: [NativeActionMenu.Action] {
        [.init(title: "Recordings & Speakers…", identifier: "ww.show.views.recordings") {
            state.recordingsPresented = true
        }] + ShowDestination.allCases.filter { $0 != .export }.enumerated().map { index, destination in
            .init(
                title: "Legacy \(destination.title)",
                identifier: "ww.show.destination.\(destination.rawValue)", separatorBefore: index == 0
            ) { state.select(destination) }
        }
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
        .frame(minWidth: 400)
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
