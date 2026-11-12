import AppKit
import SwiftUI
import WWCore

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
    var muteSpeaker: SpeakerID?
    var isBlocked = false

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(AudioTimelineToolbarAnchor.self) { anchor in
            if let anchor, listening.selectionToolsPresented, !isBlocked {
                GeometryReader { geometry in
                    let track = geometry[anchor]
                    let height = AudioTimelineSelectionToolbar.height(
                        width: track.width, cleanup: cleanup, muteSpeaker: muteSpeaker)
                    let temporary = cleanup?.selectedFiller == nil && cleanup?.selectedManualCut == nil
                        && cleanup?.selectedSpeakerMute == nil
                    ZStack(alignment: .topLeading) {
                        AudioTimelineToolbarClickAway(
                            protectedRects: protectedRects(track: track, height: height, temporary: temporary),
                            dismissOnEscape: temporary
                        ) {
                            if temporary { listening.clearSelection() }
                            else { listening.selectionToolsPresented = false }
                        }
                        AudioTimelineSelectionToolbar(listening: listening,
                            start: start, duration: duration, play: play, cleanup: cleanup, muteSpeaker: muteSpeaker,
                            trackWidth: track.width)
                            .frame(width: track.width, height: height)
                            .position(x: track.midX, y: track.minY - height / 2)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }

    private func protectedRects(track: CGRect, height: Double, temporary: Bool) -> [CGRect] {
        guard let range = cleanup?.manualCutSelection ?? listening.selection, duration > 0 else { return [] }
        let lo = max(0, (range.lowerBound - start) / duration * track.width)
        let hi = min(track.width, (range.upperBound - start) / duration * track.width)
        let width = AudioTimelineSelectionToolbar.width(
            trackWidth: track.width, cleanup: cleanup, muteSpeaker: muteSpeaker)
        let center = TimelineToolbarPlacement.center(selectionStart: lo, selectionEnd: hi,
                                                     toolbarWidth: width, trackWidth: track.width)
        var rects = [CGRect(x: track.minX + center - width / 2, y: track.minY - height,
                            width: width, height: height)]
        if temporary {
            if hi > lo {
                rects.append(CGRect(x: track.minX + lo, y: track.minY,
                                    width: hi - lo, height: track.height).insetBy(dx: -18, dy: 0))
            }
        }
        return rects
    }
}

struct AudioTimelineToolbarClickAway: NSViewRepresentable {
    var protectedRects: [CGRect] = []
    var dismissOnEscape = false
    let dismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(dismiss: dismiss)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.dismiss = dismiss
        view.protectedRects = protectedRects
        view.dismissOnEscape = dismissOnEscape
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var dismiss: () -> Void
        var protectedRects: [CGRect] = []
        var dismissOnEscape = false
        private var monitor: Any?
        override var isFlipped: Bool { true }

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
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
                [weak self] event in
                let handled = MainActor.assumeIsolated { self?.process(event) ?? false }
                return handled ? nil : event
            }
        }

        func process(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            if event.type == .keyDown {
                guard dismissOnEscape, event.keyCode == 53 else { return false }
                dismiss()
                return true
            }
            let point = convert(event.locationInWindow, from: nil)
            guard !protectedRects.contains(where: { $0.contains(point) }) else { return false }
            dismiss()
            return false
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
