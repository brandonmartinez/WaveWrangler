import AppKit

@MainActor
final class MixerNativeEditorHost: NSViewController {
    let editor: NSViewController
    private(set) var editorSize: NSSize
    let scrollView = NSScrollView()
    private let canvas = Canvas()
    private var sizeObservation: NSKeyValueObservation?
    private var frameObservation: NSObjectProtocol?
    private var scrollsVertically = false

    init(editor: NSViewController) {
        self.editor = editor
        editorSize = Self.measuredSize(editor)
        super.init(nibName: nil, bundle: nil)
        addChild(editor)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = HostView()
        root.host = self
        view = root
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = canvas
        root.addSubview(scrollView)
        editor.view.autoresizingMask = []
        canvas.addSubview(editor.view)
        editor.view.postsFrameChangedNotifications = true
        frameObservation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: editor.view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateRequestedSize(self.editor.view.frame.size)
            }
        }
        sizeObservation = editor.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateRequestedSize(Self.measuredSize(self.editor))
            }
        }
    }

    isolated deinit {
        if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
    }

    static func measuredSize(_ editor: NSViewController) -> NSSize {
        for size in [editor.preferredContentSize, editor.view.frame.size, editor.view.fittingSize] {
            if valid(size) { return size }
        }
        return NSSize(width: 640, height: 480)
    }

    private static func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func updateRequestedSize(_ size: NSSize) {
        guard Self.valid(size), size != editorSize else { return }
        editorSize = size
        if let window = view.window { configure(window, available: Self.availableContentSize(for: window)) }
        view.needsLayout = true
    }

    static func availableContentSize(for window: NSWindow) -> NSSize {
        let screen = window.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return window.contentRect(forFrameRect: frame).size
    }

    func configure(_ window: NSWindow, available: NSSize) {
        let minimumWidth = min(360, editorSize.width, available.width)
        let scale = min(1, available.width / editorSize.width, available.height / editorSize.height)
        let fitsAspect = editorSize.width * scale >= minimumWidth
        scrollsVertically = !fitsAspect
        let width = fitsAspect ? editorSize.width * scale : min(editorSize.width, available.width)
        let height = min(available.height, width * editorSize.height / editorSize.width)
        window.contentAspectRatio = .zero
        window.contentMinSize = .zero
        window.setContentSize(NSSize(width: width, height: height))
        window.contentAspectRatio = fitsAspect ? editorSize : .zero
        window.contentMinSize = NSSize(
            width: minimumWidth,
            height: fitsAspect ? minimumWidth * editorSize.height / editorSize.width : min(220, height))
    }

    private func layoutEditor() {
        scrollView.frame = view.bounds
        let available = scrollView.contentSize
        guard available.width > 0, available.height > 0 else { return }
        let scale = scrollsVertically ? available.width / editorSize.width
            : min(available.width / editorSize.width, available.height / editorSize.height)
        let width = editorSize.width * scale
        let height = editorSize.height * scale
        // Scale the complete native coordinate space, including fixed-size and remote AU views.
        // Plugin layout constraints stay inside the canvas, never becoming window constraints.
        canvas.frame = NSRect(x: max(0, (available.width - width) / 2), y: 0, width: width, height: height)
        canvas.bounds = NSRect(origin: .zero, size: editorSize)
        editor.view.frame = NSRect(origin: .zero, size: editorSize)
    }

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
    }

    private final class HostView: NSView {
        weak var host: MixerNativeEditorHost?
        override func layout() {
            super.layout()
            host?.layoutEditor()
        }
    }
}
