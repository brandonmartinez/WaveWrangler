import AppKit
import SwiftUI

struct AudioTimelineScrollSurface: NSViewRepresentable {
    var headerWidth: Double
    var handle: (AlignmentWaveformProjection.ScrollAction, Double, Double) -> Bool

    func makeNSView(context: Context) -> Surface {
        Surface(headerWidth: headerWidth, handle: handle)
    }

    func updateNSView(_ view: Surface, context: Context) {
        view.headerWidth = headerWidth
        view.handle = handle
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        view.removeMonitor()
    }

    final class Surface: NSView {
        var headerWidth: Double
        var handle: (AlignmentWaveformProjection.ScrollAction, Double, Double) -> Bool
        private var monitor: Any?

        init(
            headerWidth: Double,
            handle: @escaping (AlignmentWaveformProjection.ScrollAction, Double, Double) -> Bool
        ) {
            self.headerWidth = headerWidth
            self.handle = handle
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleScroll(event) == true ? nil : event
                }
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func handleScroll(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  visibleRect.contains(convert(event.locationInWindow, from: nil)),
                  let action = AlignmentWaveformProjection.scrollAction(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    option: event.modifierFlags.contains(.option),
                    precise: event.hasPreciseScrollingDeltas)
            else { return false }
            let width = bounds.width - headerWidth
            guard width > 0 else { return false }
            let x = convert(event.locationInWindow, from: nil).x - headerWidth
            return handle(action, min(1, max(0, x / width)), width)
        }
    }
}
