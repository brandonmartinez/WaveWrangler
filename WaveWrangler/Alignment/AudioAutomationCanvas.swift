import AppKit
import Observation
import SwiftUI
import WWCommonEdit
import WWCore

struct AudioAutomationCanvas: View {
    struct Item {
        let projected: ProgramAudioClip
        let frame: CGRect
        let key: AudioEnvelopeGeometryKey
        let geometry: AudioEnvelopeGeometry
        var clip: AudioClipID { projected.clip.id }
        var context: Context {
            .init(clip: projected, frame: frame, key: .init(
                envelope: projected.clip.envelope, durationFrames: key.durationFrames,
                programStart: key.programStart, viewportStart: key.viewportStart,
                viewportDuration: key.viewportDuration, viewportWidth: key.viewportWidth,
                left: key.left, width: key.width, height: key.height, projection: key.projection))
        }
    }
    struct Context: Equatable {
        let clip: ProgramAudioClip
        let frame: CGRect
        let key: AudioEnvelopeGeometryKey
    }
    let size: CGSize
    let items: [Item]
    let isActive: @MainActor () -> Bool
    @State private var input: AudioAutomationInput
    @State private var started = false
    @State private var horizontalCursor: Bool?
    @GestureState private var dragging = false
    @FocusState private var focused: Bool

    init(size: CGSize, items: [Item], editor: AudioClipEditorModel, isActive: @escaping @MainActor () -> Bool) {
        self.size = size
        self.items = items
        self.isActive = isActive
        _input = State(initialValue: AudioAutomationInput(editor: editor))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AudioAutomationAccessibility(size: size, items: items, focus: { item, target in
                input.focused = .init(item: item, target: target)
                focused = true
            }, nudge: { item, target, frames, level in
                guard isActive() else { return false }
                return input.nudge(item, target: target, frames: frames, level: level)
            })
            .allowsHitTesting(false)
            Canvas { context, _ in
                for item in items {
                    for point in item.geometry.points {
                        let frame = CGRect(x: item.frame.minX + point.position.x - 4,
                            y: item.frame.minY + point.position.y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: frame), with: .color(.orange))
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(HandleShape(items: items))
                .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .updating($dragging) { _, value, _ in value = true }
                    .onChanged { value in
                        guard isActive() else { input.cancel(); return }
                        if !started {
                            started = true
                            guard let (item, target) = hit(value.startLocation) else { return }
                            input.begin(item, target: target)
                            focused = true
                        }
                        input.change(.init(x: value.translation.width, y: value.translation.height))
                        cursor(input.focused?.target)
                    }
                    .onEnded { value in
                        started = false
                        guard isActive() else { input.cancel(); return }
                        input.end(.init(x: value.translation.width, y: value.translation.height))
                        cursor(nil)
                    })
                .onTapGesture { point in
                    guard isActive(), let (item, target) = hit(point) else { return }
                    input.focused = .init(item: item, target: target)
                    focused = true
                }
                .onContinuousHover { phase in
                    if input.tracking { return }
                    switch phase {
                    case .active(let point): cursor(hit(point)?.1)
                    case .ended: cursor(nil)
                    }
                }
                .focusable()
                .focused($focused)
                .onKeyPress(.escape) { started = false; input.cancel(); cursor(nil); return .handled }
                .onKeyPress(.leftArrow) { key(frames: -1, level: 0) }
                .onKeyPress(.rightArrow) { key(frames: 1, level: 0) }
                .onKeyPress(.upArrow) { key(frames: 0, level: 0.01) }
                .onKeyPress(.downArrow) { key(frames: 0, level: -0.01) }
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .disabled(!input.editor.store.canEdit || input.editor.processing != nil)
        .onChange(of: items.map(\.context)) { _, _ in input.validate(items) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
            if input.tracking { started = false; input.cancel(); cursor(nil) }
        }
        .onChange(of: dragging) { _, active in
            if !active {
                Task { @MainActor in
                    await Task.yield()
                    if !dragging, started { started = false; input.cancel(); cursor(nil) }
                }
            }
        }
        .onDisappear { input.cancel(); cursor(nil) }
    }

    private func hit(_ point: CGPoint) -> (Item, AudioAutomationTarget)? {
        for item in items {
            if let target = item.geometry.target(at: .init(x: point.x - item.frame.minX, y: point.y - item.frame.minY)) {
                return (item, target)
            }
        }
        return nil
    }

    private func cursor(_ target: AudioAutomationTarget?) {
        let next: Bool?
        switch target {
        case .point: next = true
        case .level: next = false
        case nil: next = nil
        }
        guard next != horizontalCursor else { return }
        if horizontalCursor != nil { NSCursor.pop() }
        horizontalCursor = next
        if let next { (next ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
    }

    private func key(frames: Int64, level: Double) -> KeyPress.Result {
        guard isActive(), let target = input.focused else { return .ignored }
        switch target.target {
        case .point: if frames != 0 { input.nudge(target.item, target: target.target, frames: frames, level: 0) }
        case .level: if level != 0 { input.nudge(target.item, target: target.target, frames: 0, level: level) }
        }
        return .handled
    }

    private struct HandleShape: Shape {
        let items: [Item]
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for item in items {
                for point in item.geometry.points {
                    path.addEllipse(in: CGRect(x: item.frame.minX + point.position.x - 8,
                        y: item.frame.minY + point.position.y - 8, width: 16, height: 16))
                }
                for segment in item.geometry.segments {
                    path.addRect(segment.frame.offsetBy(dx: item.frame.minX, dy: item.frame.minY))
                }
            }
            return path
        }
    }
}

@MainActor @Observable
final class AudioAutomationInput {
    struct Focus {
        let item: AudioAutomationCanvas.Item
        let target: AudioAutomationTarget
    }
    private struct Drag {
        let item: AudioAutomationCanvas.Item
        let target: AudioAutomationTarget
        var translation = CGPoint.zero
        var ready = false
        var ended = false
    }
    let editor: AudioClipEditorModel
    var focused: Focus?
    private var drag: Drag?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var operation = UUID()
    private var committedGeneration: UInt64?
    var tracking: Bool { drag != nil }

    init(editor: AudioClipEditorModel) { self.editor = editor }

    func begin(_ item: AudioAutomationCanvas.Item, target: AudioAutomationTarget) {
        cancel()
        guard item.key.envelope == item.projected.clip.envelope else {
            editor.refuse("Wait for the current curve before starting another automation drag.")
            return
        }
        focused = .init(item: item, target: target)
        drag = .init(item: item, target: target)
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

    func change(_ translation: CGPoint) {
        drag?.translation = translation; preview()
    }
    func end(_ translation: CGPoint) {
        change(translation)
        drag?.ended = true
        if drag?.ready == true { finish() }
    }
    func cancel() {
        operation = UUID()
        task?.cancel()
        task = nil
        drag = nil
        editor.cancelAutomationGesture()
    }
    func validate(_ items: [AudioAutomationCanvas.Item]) {
        if let drag, !items.contains(where: { $0.context == drag.item.context }) { cancel() }
        if let focused, !items.contains(where: { $0.context == focused.item.context }) {
            if committedGeneration == editor.store.modelGeneration,
               let current = items.first(where: { $0.clip == focused.item.clip }) {
                self.focused = .init(item: current, target: focused.target)
            } else { self.focused = nil }
        }
        committedGeneration = nil
    }

    private func preview() {
        guard let drag, drag.ready else { return }
        switch drag.target {
        case .point(let index):
            guard let point = drag.item.geometry.points.first(where: { $0.index == index }) else {
                editor.refuseAutomationGesture("This fade point is no longer visible.")
                return
            }
            let key = drag.item.key
            let display = key.viewportStart
                + (key.left + point.position.x + drag.translation.x) / key.viewportWidth * key.viewportDuration
            guard let program = key.projection.programTime(forDisplayTime: display) else {
                editor.refuseAutomationGesture("Show cut's removed audio is review-only. Move the point to production time.")
                return
            }
            let local = Double(point.local.numerator) / Double(point.local.denominator)
            let value = ((program - key.programStart) * 48_000 - local).rounded(.toNearestOrEven)
            guard value.isFinite else { editor.refuseAutomationGesture("The fade time is not finite."); return }
            let limit = Double(AudioEnvelopeCoordinate.maximumMagnitude)
            editor.previewAutomationGesture(frames: Int64(min(limit, max(-limit, value))))
        case .level:
            editor.previewAutomationGesture(levelDelta: -drag.translation.y / (drag.item.key.height - 12))
        }
    }

    private func finish() {
        if editor.completeAutomationGesture() { committedGeneration = editor.store.modelGeneration }
        drag = nil
        task = nil
    }

    @discardableResult
    func nudge(_ item: AudioAutomationCanvas.Item, target: AudioAutomationTarget, frames: Int64, level: Double) -> Bool {
        guard task == nil else { return false }
        let token = operation
        task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { if operation == token { task = nil } }
            let ready = await editor.beginAutomationGesture(clip: item.clip, target: target, expected: item.projected)
            guard operation == token, !Task.isCancelled else { return }
            guard ready else { return }
            if editor.previewAutomationGesture(frames: frames, levelDelta: level) {
                if editor.completeAutomationGesture() { committedGeneration = editor.store.modelGeneration }
            } else { editor.cancelAutomationGesture() }
        }
        return true
    }
}

private struct AudioAutomationAccessibility: NSViewRepresentable {
    let size: CGSize
    let items: [AudioAutomationCanvas.Item]
    let focus: @MainActor (AudioAutomationCanvas.Item, AudioAutomationTarget) -> Void
    let nudge: @MainActor (AudioAutomationCanvas.Item, AudioAutomationTarget, Int64, Double) -> Bool

    func makeNSView(context: Context) -> Controls { Controls(frame: .zero) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Controls, context: Context) -> CGSize? { size }
    func updateNSView(_ view: Controls, context: Context) {
        view.update(items, enabled: context.environment.isEnabled, focus: focus, nudge: nudge)
    }

    final class Controls: NSView {
        private var buttons: [String: Button] = [:]
        private var ordered: [Button] = []
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityChildren() -> [Any]? {
            let children: [Button] = MainActor.assumeIsolated { ordered }
            return children
        }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            let button: Button? = MainActor.assumeIsolated { ordered.first { $0.accessibilityFrame().contains(point) } }
            return button
        }
        func update(_ items: [AudioAutomationCanvas.Item], enabled: Bool,
                    focus: @escaping @MainActor (AudioAutomationCanvas.Item, AudioAutomationTarget) -> Void,
                    nudge: @escaping @MainActor (AudioAutomationCanvas.Item, AudioAutomationTarget, Int64, Double) -> Bool) {
            setAccessibilityElement(false)
            var current: [Button] = []
            func add(_ id: String, frame: CGRect, label: String, value: String,
                     item: AudioAutomationCanvas.Item, target: AudioAutomationTarget) {
                let button = buttons[id] ?? Button()
                if button.superview == nil { addSubview(button) }
                buttons[id] = button
                button.frame = frame
                button.isEnabled = enabled
                button.value = value
                button.perform = { focus(item, target) }
                button.setAccessibilityLabel(label)
                button.setAccessibilityIdentifier("ww.audioAutomation.\(id)")
                let point: Bool
                if case .point = target { point = true } else { point = false }
                button.setAccessibilityCustomActions([
                    .init(name: point ? "Move earlier one frame" : "Lower level one percent",
                          handler: { nudge(item, target, point ? -1 : 0, point ? 0 : -0.01) }),
                    .init(name: point ? "Move later one frame" : "Raise level one percent",
                          handler: { nudge(item, target, point ? 1 : 0, point ? 0 : 0.01) }),
                ])
                current.append(button)
            }
            for item in items {
                for point in item.geometry.points {
                    add("point.\(item.clip).\(point.index)",
                        frame: .init(x: item.frame.minX + point.position.x - 8,
                                     y: item.frame.minY + point.position.y - 8, width: 16, height: 16),
                        label: "Fade point \(point.index + 1) timing",
                        value: "Local frame \(AudioFadeInput.frameText(point.local)); amplitude \(item.key.envelope.points[point.index].amplitude)",
                        item: item, target: .point(point.index))
                }
                for (index, segment) in item.geometry.segments.enumerated() {
                    add("level.\(item.clip).\(segment.first).\(segment.last).\(index)",
                        frame: segment.frame.offsetBy(dx: item.frame.minX, dy: item.frame.minY),
                        label: "Flat fade level", value: "Amplitude \(item.key.envelope.points[segment.first].amplitude)",
                        item: item, target: .level(first: segment.first, last: segment.last))
                }
            }
            let live = Set(current.map(ObjectIdentifier.init))
            for key in Array(buttons.keys) where buttons[key].map({ !live.contains(ObjectIdentifier($0)) }) == true {
                buttons.removeValue(forKey: key)?.removeFromSuperview()
            }
            ordered = current
        }
    }
    final class Button: NSButton {
        var value = ""
        var perform: @MainActor () -> Void = {}
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
            let value: String = MainActor.assumeIsolated { self.value }
            return value
        }
        override func accessibilityFrame() -> NSRect {
            MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: self, rect: bounds) }
        }
        @objc private func activate(_ sender: NSButton) { if isEnabled { perform() } }
    }
}
