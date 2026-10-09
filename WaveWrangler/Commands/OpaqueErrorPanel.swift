import AppKit
import WWCore

/// #126: app-level error messages (e.g. the T17 recovery offer and the T20 unknown-newer refusal, shown when a
/// show could not be opened and so has no window) on an **opaque** panel. On macOS 27 an app-modal `NSAlert`
/// uses translucent material, so its text contrast depends on the wallpaper behind it (2.85:1 measured). This
/// panel draws `windowBackgroundColor` edge to edge with `labelColor` text, which keeps ≥ 4.5:1 in both
/// appearances whatever is behind the window.
///
/// Wording and buttons are the ones `NSAlert(error:)` shows: message = `localizedDescription`, informative
/// text = `localizedRecoverySuggestion`, buttons = `localizedRecoveryOptions` (or OK), first button trailing.
/// Keys follow A13: the first option is normally Return's default; an explicitly selected recovery offer
/// has no Return action. A button titled "Cancel" (or the only button) answers Esc. Recovery goes through
/// the error's own recovery attempter, exactly as `presentError` does.
///
/// Also compiled into the unhosted WaveWranglerTests target, so content, keys and opacity are checked
/// without launching the app.
struct OpaqueErrorContent: Equatable {
    static let requiresExplicitSelectionKey = "WWRecoveryRequiresExplicitSelection"
    static let recoveryPlanKey = "WWRecoveryChoicePlan"
    var message: String
    var informative: String
    var options: [String]
    var recoveryPlan: RecoveryChoicePresentation.Plan?
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
        recoveryPlan = error.userInfo[Self.recoveryPlanKey] as? RecoveryChoicePresentation.Plan
        if let recoveryPlan {
            precondition(options.count == recoveryPlan.choices.count + 1,
                         "Recovery options and choice plan must agree")
        }
        let cancel = options.firstIndex(of: String(localized: "Cancel"))
        cancelIndex = cancel ?? (options.count == 1 ? 0 : nil)
        let requiresExplicitSelection = error.userInfo[Self.requiresExplicitSelectionKey] as? Bool == true
        if let recoveryPlan {
            defaultIndex = recoveryPlan.defaultRecordID.flatMap { id in
                recoveryPlan.choices.firstIndex { $0.record.recordID == id }
            }
        } else {
            defaultIndex = requiresExplicitSelection || (cancel == 0 && options.count > 1) ? nil : 0
        }
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
    private var choicePlan: RecoveryChoicePresentation.Plan?
    private var pageIndex = 0
    private var previousPageButton: NSButton?
    private var nextPageButton: NSButton?

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers {
            if key == "]", nextPageButton?.isHidden == false { showPage(pageIndex + 1); return true }
            if key == "[", previousPageButton?.isHidden == false { showPage(pageIndex - 1); return true }
            if let digit = Int(key), (1...9).contains(digit), let choicePlan,
               choicePlan.pages.indices.contains(pageIndex),
               choicePlan.pages[pageIndex].choices.indices.contains(digit - 1) {
                let id = choicePlan.pages[pageIndex].choices[digit - 1].record.recordID
                guard let index = choicePlan.choices.firstIndex(where: { $0.record.recordID == id }) else {
                    preconditionFailure("Recovery page lost its choice")
                }
                onChoose?(index)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func previousPage(_ sender: NSButton) { showPage(pageIndex - 1) }
    @objc private func nextPage(_ sender: NSButton) { showPage(pageIndex + 1) }

    private func showPage(_ index: Int) {
        guard let choicePlan, choicePlan.pages.indices.contains(index) else { return }
        pageIndex = index
        let visible = Set(choicePlan.pages[index].choices.map(\.record.recordID))
        for (offset, choice) in choicePlan.choices.enumerated() {
            optionButtons[offset].isHidden = !visible.contains(choice.record.recordID)
        }
        previousPageButton?.isHidden = choicePlan.pages[index].previousShortcut == nil
        nextPageButton?.isHidden = choicePlan.pages[index].nextShortcut == nil
        contentView?.layoutSubtreeIfNeeded()
        setContentSize(contentView?.fittingSize ?? contentRect(forFrameRect: frame).size)
    }

    private func buildContent() {
        let background = OpaqueBackgroundView()

        // No icon: the mini's XCUITest audit flagged a decorative app icon (unlabelled image, "potentially
        // inaccessible text") even with `setAccessibilityElement(false)`. The message carries the meaning.
        messageField = Self.label(content.message, font: .boldSystemFont(ofSize: NSFont.systemFontSize), identifier: "ww.app.errorDialog.message")
        informativeField = Self.label(content.informative, font: .systemFont(ofSize: NSFont.systemFontSize), identifier: "ww.app.errorDialog.informative")
        informativeField.isHidden = content.informative.isEmpty

        let texts = NSStackView(views: [messageField, informativeField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8

        if let plan = content.recoveryPlan {
            choicePlan = plan
        } else if content.defaultIndex == nil, content.options.count > 1 {
            choicePlan = RecoveryChoicePresentation.plan(records: content.options.indices
                .filter { $0 != content.cancelIndex }
                .map { index in
                    .init(recordID: String(format: "%010d", index), kind: .unsavedCheckpoint,
                          documentID: "", savedAt: nil, createdAt: nil, revision: nil, disposition: .open)
                })
        }
        optionButtons = content.options.enumerated().map { index, title in
            let choice = choicePlan?.choices.indices.contains(index) == true ? choicePlan?.choices[index] : nil
            let label = if let choice, !title.contains(choice.shortcut) {
                "\(choice.shortcut) \(title)"
            } else {
                title
            }
            let button = NSButton(title: label, target: self, action: #selector(chooseOption(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.setAccessibilityIdentifier("ww.app.errorDialog.option.\(index)")
            button.setAccessibilityLabel(label)
            if let choice {
                button.keyEquivalent = String(choice.shortcut.suffix(1))
                button.keyEquivalentModifierMask = .command
            } else {
                button.keyEquivalent = index == content.defaultIndex ? "\r" : (index == content.cancelIndex ? "\u{1b}" : "")
            }
            return button
        }
        if let choicePlan, choicePlan.pages.count > 1 {
            let previous = NSButton(title: "Previous Recovery Page (⌘[)", target: self, action: #selector(previousPage(_:)))
            previous.keyEquivalent = "["
            previous.keyEquivalentModifierMask = .command
            previous.setAccessibilityLabel(previous.title)
            previousPageButton = previous
            let next = NSButton(title: "Next Recovery Page (⌘])", target: self, action: #selector(nextPage(_:)))
            next.keyEquivalent = "]"
            next.keyEquivalentModifierMask = .command
            next.setAccessibilityLabel(next.title)
            nextPageButton = next
        }
        // Keep longer, individually labelled recovery choices inside a narrow, keyboard-reachable dialog.
        let buttons = choicePlan == nil
            ? Array(optionButtons.reversed())
            : optionButtons + [previousPageButton, nextPageButton].compactMap { $0 }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = choicePlan == nil ? .horizontal : .vertical
        buttonRow.alignment = choicePlan == nil ? .centerY : .trailing
        buttonRow.spacing = 12

        let column = NSStackView(views: [texts, buttonRow])
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
            texts.widthAnchor.constraint(equalToConstant: 400),
        ])
        contentView = background
        setContentSize(background.fittingSize)
        if choicePlan != nil { showPage(0) }
        defaultButtonCell = content.defaultIndex.flatMap { optionButtons[$0].cell as? NSButtonCell }
        initialFirstResponder = (content.defaultIndex ?? content.cancelIndex).map { optionButtons[$0] } ?? optionButtons.first
    }

    private static func label(_ text: String, font: NSFont, identifier: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = .labelColor
        field.drawsBackground = false
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 400
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
    /// Where `WaveWranglerApplication` sends an error presentation.
    enum Route: Equatable {
        /// AppKit's own sheet on the window (it applies `willPresentError` and cancellation itself).
        case sheet
        /// App-modal on the opaque panel.
        case opaquePanel
        /// Not shown: the user cancelled (AppKit never presents `NSUserCancelledError`).
        case suppressed
    }

    /// The parts of the target window the route depends on.
    struct WindowState: Equatable {
        var isVisible: Bool
        var isMiniaturized: Bool

        init(isVisible: Bool, isMiniaturized: Bool) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }

        init(_ window: NSWindow) {
            self.init(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized)
        }
    }

    /// Only an on-screen window gets AppKit's sheet. A hidden or miniaturized window, or none, gets the opaque
    /// panel, deliberately: a sheet on a window in the Dock would be out of sight until the window is restored,
    /// while the panel is shown at once. `error` is the one after `prepare` (cancellation is checked on it).
    static func route(for error: Error, window: WindowState?) -> Route {
        if (error as NSError).userInfo[OpaqueErrorContent.requiresExplicitSelectionKey] as? Bool == true {
            return .opaquePanel
        }
        if let window, window.isVisible, !window.isMiniaturized { return .sheet }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError ? .suppressed : .opaquePanel
    }

    /// AppKit's `willPresentError` step for app-level presentation: the app delegate may replace the error.
    static func prepare(_ error: Error, delegate: NSApplicationDelegate?, application: NSApplication) -> Error {
        delegate?.application?(application, willPresentError: error) ?? error
    }

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
