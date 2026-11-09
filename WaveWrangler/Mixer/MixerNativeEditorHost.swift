import AppKit

@MainActor
final class MixerNativeEditorHost: NSViewController {
    let editor: NSViewController
    private(set) var editorSize: NSSize
    let scrollView = NSScrollView()
    private let canvas = Canvas()
    private var sizeObservation: NSKeyValueObservation?

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
        sizeObservation = editor.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editorSize = Self.measuredSize(self.editor)
                if let window = self.view.window {
                    self.configure(window, available: Self.availableContentSize(for: window))
                }
                self.view.needsLayout = true
            }
        }
    }

    static func measuredSize(_ editor: NSViewController) -> NSSize {
        for size in [editor.preferredContentSize, editor.view.fittingSize, editor.view.frame.size] {
            if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                return size
            }
        }
        return NSSize(width: 640, height: 480)
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
        let width = fitsAspect ? editorSize.width * scale : min(editorSize.width, available.width)
        let height = min(available.height, width * editorSize.height / editorSize.width)
        window.contentAspectRatio = fitsAspect ? editorSize : .zero
        window.contentMinSize = NSSize(
            width: minimumWidth,
            height: fitsAspect ? minimumWidth * editorSize.height / editorSize.width : min(220, height))
        window.setContentSize(NSSize(width: width, height: height))
    }

    private func layoutEditor() {
        scrollView.frame = view.bounds
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        let height = width * editorSize.height / editorSize.width
        // Scale the complete native coordinate space, including fixed-size and remote AU views.
        // Plugin layout constraints stay inside the canvas, never becoming window constraints.
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
