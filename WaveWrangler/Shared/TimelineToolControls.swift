import AppKit
import SwiftUI

struct TimelineToolControls: View {
    @Bindable var listening: EpisodeListeningState

    var body: some View {
        HStack(spacing: 4) {
            selector("Primary tool", selection: $listening.tool, command: false)
            selector("Command-click tool", selection: $listening.commandTool, command: true)
        }
        .background(TimelineToolModifierMonitor(listening: listening).frame(width: 0, height: 0))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline tools")
        .accessibilityValue(listening.effectiveTool.rawValue)
        .accessibilityIdentifier("alignment.waveforms.tools")
    }

    private func selector(_ title: String, selection: Binding<EpisodeListeningState.Tool>, command: Bool) -> some View {
        NativeActionMenu(label: title, symbol: selection.wrappedValue.symbol,
            identifier: command ? "alignment.waveforms.commandTool" : "alignment.waveforms.tool",
            value: selection.wrappedValue.rawValue, prefix: command ? "⌘" : nil,
            actions: EpisodeListeningState.Tool.allCases.map { tool in
                .init(title: tool.rawValue, symbol: tool.symbol, isSelected: tool == selection.wrappedValue) {
                    selection.wrappedValue = tool
                }
            })
        .frame(width: command ? 58 : 44, height: 24)
        .padding(2)
        .background((listening.commandHeld == command ? Color.accentColor : .clear).opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 5))
        .help(command
              ? "Hold Command to use \(selection.wrappedValue.rawValue); release to restore the primary tool."
              : "Pointer selects intervals. Move recorder respects position locks. Reviewed and Reject act only on existing filler regions.")
    }
}

struct TimelineToolModifierMonitor: NSViewRepresentable {
    let listening: EpisodeListeningState

    func makeNSView(context: Context) -> MonitorView { MonitorView(listening: listening) }
    func updateNSView(_ nsView: MonitorView, context: Context) { nsView.updateListening(listening) }
    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) { nsView.stop() }

    final class MonitorView: NSView {
        private(set) var listening: EpisodeListeningState
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?

        init(listening: EpisodeListeningState) {
            self.listening = listening
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .leftMouseUp]) {
                [weak self] event in
                guard let self, (event.window ?? NSApp.keyWindow) === self.window, self.window?.isKeyWindow == true,
                      self.window?.attachedSheet == nil else { return event }
                self.process(event)
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.listening.updateCommandModifier(false) }
            }
        }

        func process(_ event: NSEvent) {
            listening.updateCommandModifier(event.modifierFlags.contains(.command))
        }

        func updateListening(_ value: EpisodeListeningState) {
            guard listening !== value else { return }
            listening.updateCommandModifier(false)
            listening = value
            listening.updateCommandModifier(window?.isKeyWindow == true && window?.attachedSheet == nil
                && NSEvent.modifierFlags.contains(.command))
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            listening.updateCommandModifier(false)
        }
    }
}
