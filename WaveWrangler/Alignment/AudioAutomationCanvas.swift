import AppKit
import SwiftUI
import WWCommonEdit
import WWCore

struct AudioAutomationCanvas: NSViewRepresentable {
    struct Item {
        let projected: ProgramAudioClip
        let frame: CGRect
        let key: AudioEnvelopeGeometryKey
        let geometry: AudioEnvelopeGeometry
        var clip: AudioClipID { projected.clip.id }
    }

    let size: CGSize
    let items: [Item]
    let editor: AudioClipEditorModel
    let isActive: @MainActor () -> Bool

    func makeNSView(context: Context) -> CanvasView { CanvasView(editor: editor) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CanvasView, context: Context) -> CGSize? { size }
    func updateNSView(_ view: CanvasView, context: Context) {
        if view.frame.size != size { view.setFrameSize(size) }
        view.update(items, enabled: context.environment.isEnabled, isActive: isActive)
    }
    static func dismantleNSView(_ view: CanvasView, coordinator: ()) { view.stop() }

    @MainActor
    final class CanvasView: NSView {
        private struct Drag {
            let item: Item
            let target: AudioAutomationTarget
            let origin: CGPoint
            let windowFrame: CGRect
            var translation = CGPoint.zero
            var ready = false
            var ended = false
        }
        let editor: AudioClipEditorModel
        private var items: [Item] = []
        private var enabled = true
        private var active: @MainActor () -> Bool = { false }
        private var drag: Drag?
        private var task: Task<Void, Never>?
        private var operation = UUID()
        private var focused: (AudioClipID, AudioAutomationTarget)?
        private var observer: NSObjectProtocol?
        private var buttons: [String: HandleButton] = [:]
        private var orderedButtons: [HandleButton] = []

        init(editor: AudioClipEditorModel) {
            self.editor = editor
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { cancel(); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        }

        func stop() {
            cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func update(_ items: [Item], enabled: Bool, isActive: @escaping @MainActor () -> Bool) {
            if let drag {
                let current = items.first { $0.clip == drag.item.clip }
                if !enabled || !isActive() || current?.frame != drag.item.frame
                    || current?.key.viewportStart != drag.item.key.viewportStart
                    || current?.key.viewportDuration != drag.item.key.viewportDuration
                    || current?.key.viewportWidth != drag.item.key.viewportWidth
                    || current?.key.programStart != drag.item.key.programStart
                    || current?.key.durationFrames != drag.item.key.durationFrames
                    || current?.key.left != drag.item.key.left
                    || current?.key.height != drag.item.key.height
                    || current?.key.projection != drag.item.key.projection
                    || convert(bounds, to: nil) != drag.windowFrame
                    || drag.ready && editor.automationGesture == nil {
                    cancel()
                }
            }
            self.items = items
            if let focused, !items.contains(where: { $0.clip == focused.0 }) { self.focused = nil }
            self.enabled = enabled
            active = isActive
            updateButtons()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard enabled, active(), bounds.contains(local),
                  items.contains(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(local) }) else { return nil }
            return self
        }

        override func resetCursorRects() {
            for item in items {
                for segment in item.geometry.segments {
                    addCursorRect(segment.frame.offsetBy(dx: item.frame.minX, dy: item.frame.minY), cursor: .resizeUpDown)
                }
                for point in item.geometry.points {
                    addCursorRect(pointFrame(point.position, in: item), cursor: .resizeLeftRight)
                }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemOrange.setFill()
            for item in items {
                for point in item.geometry.points {
                    let frame = pointFrame(point.position, in: item).insetBy(dx: 4, dy: 4)
                    NSBezierPath(ovalIn: frame).fill()
                }
            }
            if window?.isKeyWindow == true, let focused,
               let item = items.first(where: { $0.clip == focused.0 }) {
                NSColor.controlAccentColor.setStroke()
                switch focused.1 {
                case .point(let index):
                    if let point = item.geometry.points.first(where: { $0.index == index }) {
                        NSBezierPath(ovalIn: pointFrame(point.position, in: item).insetBy(dx: 2, dy: 2)).stroke()
                    }
                case .level(let first, let last):
                    for segment in item.geometry.segments where segment.first == first && segment.last == last {
                        NSBezierPath(rect: segment.frame.offsetBy(dx: item.frame.minX, dy: item.frame.minY)).stroke()
                    }
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            cancel()
            guard enabled, active(), editor.store.canEdit, window?.attachedSheet == nil else { return }
            let origin = convert(event.locationInWindow, from: nil)
            guard let item = items.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(origin) }),
                  let target = item.geometry.target(at: .init(x: origin.x - item.frame.minX, y: origin.y - item.frame.minY))
            else { return }
            guard item.key.envelope == item.projected.clip.envelope else {
                editor.refuse("Wait for the current curve before starting another automation drag.")
                return
            }
            window?.makeFirstResponder(self)
            focused = (item.clip, target)
            switch target {
            case .point: NSCursor.resizeLeftRight.set()
            case .level: NSCursor.resizeUpDown.set()
            }
            drag = .init(item: item, target: target, origin: origin, windowFrame: convert(bounds, to: nil))
            let token = operation
            task = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let ready = await editor.beginAutomationGesture(clip: item.clip, target: target, expected: item.projected)
                guard operation == token, !Task.isCancelled else { return }
                guard ready else { cancel(); return }
                drag?.ready = true
                preview()
                if drag?.ended == true { finish() }
            }
        }

        override func mouseDragged(with event: NSEvent) { updateDrag(event); preview() }
        override func mouseUp(with event: NSEvent) {
            updateDrag(event)
            drag?.ended = true
            if drag?.ready == true { preview(); finish() }
        }

        private func updateDrag(_ event: NSEvent) {
            guard let current = drag else { return }
            let position = convert(event.locationInWindow, from: nil)
            drag?.translation = .init(x: position.x - current.origin.x, y: position.y - current.origin.y)
        }

        private func preview() {
            guard let drag, drag.ready else { return }
            guard active(), convert(bounds, to: nil) == drag.windowFrame else { cancel(); return }
            switch drag.target {
            case .point(let index):
                NSCursor.resizeLeftRight.set()
                guard let point = drag.item.geometry.points.first(where: { $0.index == index }) else {
                    editor.refuseAutomationGesture("This fade point is no longer visible.")
                    return
                }
                let key = drag.item.key
                let display = key.viewportStart
                    + (key.left + point.position.x + drag.translation.x) / key.viewportWidth * key.viewportDuration
                guard let program = key.projection.programTime(forDisplayTime: display) else {
                    editor.refuseAutomationGesture("Show cut's removed audio is review-only. Move the fade point to production time.")
                    return
                }
                let local = Double(point.local.numerator) / Double(point.local.denominator)
                let value = ((program - key.programStart) * 48_000 - local).rounded(.toNearestOrEven)
                guard value.isFinite else { editor.refuseAutomationGesture("The fade time is not finite."); return }
                let limit = Double(AudioEnvelopeCoordinate.maximumMagnitude)
                editor.previewAutomationGesture(frames: Int64(min(limit, max(-limit, value))))
            case .level:
                NSCursor.resizeUpDown.set()
                editor.previewAutomationGesture(levelDelta: -drag.translation.y / (drag.item.key.height - 12))
            }
        }

        private func finish() {
            guard active() else { cancel(); return }
            _ = editor.completeAutomationGesture()
            drag = nil
            task = nil
            window?.invalidateCursorRects(for: self)
        }

        private func cancel() {
            operation = UUID()
            task?.cancel()
            task = nil
            drag = nil
            editor.cancelAutomationGesture()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel(); return }
            guard let focused, [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
            switch focused.1 {
            case .point:
                if event.keyCode == 123 || event.keyCode == 124 {
                    nudge(focused.0, target: focused.1, frames: event.keyCode == 123 ? -1 : 1)
                }
            case .level:
                if event.keyCode == 125 || event.keyCode == 126 {
                    nudge(focused.0, target: focused.1, level: event.keyCode == 125 ? -0.01 : 0.01)
                }
            }
        }

        @discardableResult
        private func nudge(_ clip: AudioClipID, target: AudioAutomationTarget, frames: Int64 = 0, level: Double = 0) -> Bool {
            guard enabled, active(), task == nil, window?.attachedSheet == nil,
                  let item = items.first(where: { $0.clip == clip }) else { return false }
            let token = operation
            task = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                defer { if operation == token { task = nil } }
                let ready = await editor.beginAutomationGesture(clip: clip, target: target, expected: item.projected)
                guard operation == token, !Task.isCancelled else { return }
                guard ready, active() else { editor.cancelAutomationGesture(); return }
                if editor.previewAutomationGesture(frames: frames, levelDelta: level) {
                    _ = editor.completeAutomationGesture()
                }
            }
            return true
        }

        private func pointFrame(_ position: CGPoint, in item: Item) -> CGRect {
            CGRect(x: item.frame.minX + position.x - 8, y: item.frame.minY + position.y - 8, width: 16, height: 16)
        }

        private func updateButtons() {
            var ordered: [HandleButton] = []
            func add(_ id: String, frame: CGRect, label: String, value: String, item: Item, target: AudioAutomationTarget) {
                let button = buttons[id] ?? HandleButton()
                if button.superview == nil { addSubview(button) }
                buttons[id] = button
                let visible = frame.intersection(bounds)
                guard !visible.isNull, !visible.isEmpty else { return }
                button.frame = visible
                button.isEnabled = enabled && editor.store.canEdit
                button.setAccessibilityIdentifier("ww.audioAutomation.\(id)")
                button.setAccessibilityLabel(label)
                button.programValue = value
                button.perform = { [weak self] in
                    self?.focused = (item.clip, target)
                    self?.window?.makeFirstResponder(self)
                    self?.needsDisplay = true
                }
                let point: Bool
                if case .point = target { point = true } else { point = false }
                button.setAccessibilityCustomActions([
                    .init(name: point ? "Move earlier one frame" : "Lower level one percent", handler: { [weak self] in
                        self?.nudge(item.clip, target: target, frames: point ? -1 : 0, level: point ? 0 : -0.01) ?? false
                    }),
                    .init(name: point ? "Move later one frame" : "Raise level one percent", handler: { [weak self] in
                        self?.nudge(item.clip, target: target, frames: point ? 1 : 0, level: point ? 0 : 0.01) ?? false
                    }),
                ])
                ordered.append(button)
            }
            for item in items {
                for point in item.geometry.points {
                    let value = item.key.envelope.points[point.index].amplitude
                    add("point.\(item.clip).\(point.index)", frame: pointFrame(point.position, in: item),
                        label: "Fade point \(point.index + 1) timing",
                        value: "Local frame \(AudioFadeInput.frameText(point.local)); amplitude \(value)",
                        item: item, target: .point(point.index))
                }
                for (index, segment) in item.geometry.segments.enumerated() {
                    add("level.\(item.clip).\(segment.first).\(segment.last).\(index)",
                        frame: segment.frame.offsetBy(dx: item.frame.minX, dy: item.frame.minY),
                        label: "Flat fade level", value: "Amplitude \(item.key.envelope.points[segment.first].amplitude)",
                        item: item, target: .level(first: segment.first, last: segment.last))
                }
            }
            let live = Set(ordered.map(ObjectIdentifier.init))
            for key in Array(buttons.keys) where buttons[key].map({ !live.contains(ObjectIdentifier($0)) }) == true {
                buttons.removeValue(forKey: key)?.removeFromSuperview()
            }
            orderedButtons = ordered
        }

        override func accessibilityChildren() -> [Any]? {
            let children: [HandleButton] = MainActor.assumeIsolated { orderedButtons }
            return children
        }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            let button: HandleButton? = MainActor.assumeIsolated {
                orderedButtons.first { $0.accessibilityFrame().contains(point) }
            }
            return button
        }
    }

    final class HandleButton: NSButton {
        var perform: @MainActor () -> Void = {}
        var programValue = ""
        init() {
            super.init(frame: .zero)
            title = ""
            isBordered = false
            setButtonType(.momentaryPushIn)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            target = self
            action = #selector(activate(_:))
        }
        required init?(coder: NSCoder) { nil }
        override func accessibilityValue() -> Any? {
            let value: String = MainActor.assumeIsolated { programValue }
            return value
        }
        override func accessibilityFrame() -> NSRect {
            MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: self, rect: bounds) }
        }
        @objc private func activate(_ sender: NSButton) { if isEnabled { perform() } }
    }
}
