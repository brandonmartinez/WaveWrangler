import AppKit

/// #126: app-level error messages (e.g. the T17 recovery offer and the T20 unknown-newer refusal, shown when a
/// show could not be opened and so has no window) on an **opaque** panel. On macOS 27 an app-modal `NSAlert`
/// uses translucent material, so its text contrast depends on the wallpaper behind it (2.85:1 measured). This
/// panel draws `windowBackgroundColor` edge to edge with `labelColor` text, which keeps ≥ 4.5:1 in both
/// appearances whatever is behind the window.
///
/// Wording and buttons are the ones `NSAlert(error:)` shows: message = `localizedDescription`, informative
/// text = `localizedRecoverySuggestion`, buttons = `localizedRecoveryOptions` (or OK), first button trailing.
/// Keys follow A13: the first option is the default (Return); a button titled "Cancel" (or the only button)
/// answers Esc. Recovery goes through the error's own recovery attempter, exactly as `presentError` does.
///
/// Also compiled into the unhosted WaveWranglerTests target, so content, keys and opacity are checked
/// without launching the app.
struct OpaqueErrorContent: Equatable {
    var message: String
    var informative: String
    var options: [String]
    /// The option that answers Return.
    var defaultIndex: Int?
    /// The option that answers Esc.
    var cancelIndex: Int?

    init(error: Error) {
        let error = error as NSError
        message = error.localizedDescription
        informative = error.localizedRecoverySuggestion ?? ""
        let recoveryOptions = error.localizedRecoveryOptions ?? []
        options = recoveryOptions.isEmpty ? [String(localized: "OK")] : recoveryOptions
        let cancel = options.firstIndex(of: String(localized: "Cancel"))
        cancelIndex = cancel ?? (options.count == 1 ? 0 : nil)
        defaultIndex = cancel == 0 && options.count > 1 ? nil : 0
    }
}

/// The opaque panel. `onChoose` receives the chosen option index; `OpaqueErrorPresenter` runs it modally.
final class OpaqueErrorPanel: NSPanel {
    static let identifier = "ww.app.errorDialog"

    let content: OpaqueErrorContent
    /// Buttons in option order (index 0 is the trailing, default one).
    private(set) var optionButtons: [NSButton] = []
    private(set) var messageField: NSTextField!
    private(set) var informativeField: NSTextField!
    var onChoose: ((Int) -> Void)?

    init(error: Error) {
        content = OpaqueErrorContent(error: error)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // The window title is what VoiceOver announces for the dialog; it is hidden visually.
        title = content.message
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .alertPanel
        setAccessibilityIdentifier(Self.identifier)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        buildContent()
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }

    override var canBecomeKey: Bool { true }

    /// Esc (and ⌘.) choose the Cancel option when there is one.
    override func cancelOperation(_ sender: Any?) {
        if let index = content.cancelIndex { onChoose?(index) }
    }

    @objc private func chooseOption(_ sender: NSButton) {
        onChoose?(sender.tag)
    }

    private func buildContent() {
        let background = OpaqueBackgroundView()

        let icon = NSImageView(image: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])

        messageField = Self.label(content.message, font: .boldSystemFont(ofSize: NSFont.systemFontSize), identifier: "ww.app.errorDialog.message")
        informativeField = Self.label(content.informative, font: .systemFont(ofSize: NSFont.systemFontSize), identifier: "ww.app.errorDialog.informative")
        informativeField.isHidden = content.informative.isEmpty

        let texts = NSStackView(views: [messageField, informativeField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8

        let top = NSStackView(views: [icon, texts])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 16

        optionButtons = content.options.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(chooseOption(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.setAccessibilityIdentifier("ww.app.errorDialog.option.\(index)")
            button.keyEquivalent = index == content.defaultIndex ? "\r" : (index == content.cancelIndex ? "\u{1b}" : "")
            return button
        }
        // NSAlert order: the first option is trailing.
        let buttonRow = NSStackView(views: optionButtons.reversed())
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let column = NSStackView(views: [top, buttonRow])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 20
        column.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            top.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            texts.widthAnchor.constraint(equalToConstant: 340),
        ])
        contentView = background
        setContentSize(background.fittingSize)
        initialFirstResponder = content.defaultIndex.map { optionButtons[$0] } ?? optionButtons.first
    }

    private static func label(_ text: String, font: NSFont, identifier: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = .labelColor
        field.drawsBackground = false
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 340
        field.setAccessibilityIdentifier(identifier)
        return field
    }
}

/// Fills its bounds with the window background colour; never translucent.
final class OpaqueBackgroundView: NSView {
    static let fill = NSColor.windowBackgroundColor

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        dirtyRect.fill()
    }
}

@MainActor
enum OpaqueErrorPresenter {
    /// App-modal presentation, like `NSApplication.presentError(_:)`. Returns whether recovery succeeded.
    @discardableResult
    static func presentModally(_ error: Error) -> Bool {
        let panel = OpaqueErrorPanel(error: error)
        panel.onChoose = { index in
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        }
        panel.center()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard panel.content.options.indices.contains(index) else { return false }
        return attemptRecovery(from: error, optionIndex: index)
    }

    /// Calls the delegate's did-present selector with AppKit's signature
    /// `- (void)didPresentErrorWithRecovery:(BOOL)didRecover contextInfo:(void *)contextInfo`.
    static func notify(_ delegate: Any?, didPresent selector: Selector?, didRecover: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let object = delegate as? NSObject, let selector, object.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, ObjCBool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(object.method(for: selector), to: Callback.self)(object, selector, ObjCBool(didRecover), contextInfo)
    }

    /// Same contract as AppKit's error presentation: only an error that offers recovery options is handed to
    /// its `NSRecoveryAttempterErrorKey` object (e.g. the copy-only `DocumentRecoveryOffer.RecoveryAttempter`).
    static func attemptRecovery(from error: Error, optionIndex: Int) -> Bool {
        let error = error as NSError
        guard !(error.localizedRecoveryOptions ?? []).isEmpty,
              let attempter = error.recoveryAttempter as? NSObject,
              attempter.responds(to: #selector(NSObject.attemptRecovery(fromError:optionIndex:)))
        else { return false }
        return attempter.attemptRecovery(fromError: error, optionIndex: optionIndex)
    }
}
