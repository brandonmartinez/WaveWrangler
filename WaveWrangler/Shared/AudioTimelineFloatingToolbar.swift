import AppKit
import SwiftUI

struct AudioTimelineToolbarAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct AudioTimelineFloatingToolbar: ViewModifier {
    @Bindable var listening: EpisodeListeningState
    let start: Double
    let duration: Double
    let play: (Double) -> Void
    var cleanup: EpisodeCleanupModel?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(AudioTimelineToolbarAnchor.self) { anchor in
            if let anchor, listening.selectionToolsPresented {
                GeometryReader { geometry in
                    let track = geometry[anchor]
                    let height = AudioTimelineSelectionToolbar.height(
                        width: track.width, cleanup: cleanup)
                    AudioTimelineSelectionToolbar(listening: listening,
                        start: start, duration: duration, play: play, cleanup: cleanup,
                        trackWidth: track.width)
                        .frame(width: track.width, height: height)
                        .position(x: track.midX, y: track.minY - height / 2)
                }
            }
        }
    }
}

struct AudioTimelineToolbarClickAway: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(dismiss: dismiss) }
    func updateNSView(_ view: MonitorView, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var dismiss: () -> Void
        private var monitor: Any?

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.process(event) }
                return event
            }
        }

        func process(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            dismiss()
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
