import AppKit
import Testing
import WWPersistence

/// #126: the T17 recovery offer and T20 unknown-newer refusal are shown without a window. They use
/// `OpaqueErrorPanel` (compiled into this unhosted target) instead of a translucent app-modal `NSAlert`.
/// These checks run without the app: wording, keys (A13), copy-only recovery hand-off, and an opaque surface
/// whose text meets 4.5:1 in light and dark appearance whatever is behind the window.
@MainActor
@Suite("Opaque error panel")
struct OpaqueErrorPanelTests {
    /// What `DocumentRecoveryOffer.error` produces for a damaged show with a kept complete revision.
    private static func recoveryOffer(attempter: Attempter) -> NSError {
        NSError(domain: "com.brandonmartinez.wavewrangler.persistence", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The document “Recover.wwshow” could not be opened.",
            NSLocalizedFailureReasonErrorKey: "Truncated JSON.",
            NSLocalizedRecoverySuggestionErrorKey:
                "A complete earlier revision (3) is kept on this Mac. You can open it as a new, unsaved copy. The damaged file is left unchanged.",
            NSLocalizedRecoveryOptionsErrorKey: ["Open Recovered Copy", "Cancel"],
            NSRecoveryAttempterErrorKey: attempter,
        ])
    }

    private static let refusal = PersistenceError.unknownNewerSchema(found: 99, supported: 1)

    /// Records the option AppKit-style presentation hands to the recovery attempter.
    final class Attempter: NSObject {
        var chosen: [Int] = []
        override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
            chosen.append(recoveryOptionIndex)
            return recoveryOptionIndex == 0
        }
    }

    // MARK: - Wording and keys

    @Test func recoveryOfferKeepsNSAlertWordingAndButtons() {
        let error = Self.recoveryOffer(attempter: Attempter())
        let content = OpaqueErrorContent(error: error)
        let alert = NSAlert(error: error)
        #expect(content.message == alert.messageText)
        #expect(content.informative == alert.informativeText)
        #expect(content.options == alert.buttons.map(\.title))
        #expect(content.options == ["Open Recovered Copy", "Cancel"])
        #expect(!content.message.contains("Saved") && !content.informative.contains("Saved"), "never claims Saved")
        #expect(content.defaultIndex == 0, "Return opens the recovered copy (chosen, non-destructive)")
        #expect(content.cancelIndex == 1, "Esc cancels")
    }

    @Test func refusalKeepsNSAlertWordingAndDismissesWithReturnOrEsc() {
        let content = OpaqueErrorContent(error: Self.refusal)
        let alert = NSAlert(error: Self.refusal)
        #expect(content.message == alert.messageText)
        #expect(content.informative == alert.informativeText)
        #expect(content.options == alert.buttons.map(\.title))
        #expect(content.options.count == 1)
        #expect(content.message.contains("newer version of WaveWrangler"))
        #expect(content.informative == "Open it with the newer version of WaveWrangler. This version will not edit or save it, so no newer work is lost.")
        #expect(content.defaultIndex == 0 && content.cancelIndex == 0)
    }

    @Test func panelButtonsCarryTheKeysInNSAlertOrder() {
        let panel = OpaqueErrorPanel(error: Self.recoveryOffer(attempter: Attempter()))
        #expect(panel.optionButtons.map(\.title) == ["Open Recovered Copy", "Cancel"])
        #expect(panel.optionButtons[0].keyEquivalent == "\r")
        #expect(panel.optionButtons[1].keyEquivalent == "\u{1b}")
        #expect(panel.optionButtons.filter(\.hasDestructiveAction).isEmpty)
        #expect(panel.initialFirstResponder === panel.optionButtons[0])
        // The first option is trailing, as in NSAlert.
        panel.contentView?.layoutSubtreeIfNeeded()
        let open = panel.optionButtons[0].convert(panel.optionButtons[0].bounds, to: nil)
        let cancel = panel.optionButtons[1].convert(panel.optionButtons[1].bounds, to: nil)
        #expect(open.minX > cancel.maxX)
    }

    @Test func clicksReturnAndEscReportTheChosenOption() {
        let panel = OpaqueErrorPanel(error: Self.recoveryOffer(attempter: Attempter()))
        var chosen: [Int] = []
        panel.onChoose = { chosen.append($0) }
        panel.optionButtons[0].performClick(nil)
        panel.optionButtons[1].performClick(nil)
        panel.cancelOperation(nil)
        #expect(chosen == [0, 1, 1])

        let refusal = OpaqueErrorPanel(error: Self.refusal)
        var dismissed: [Int] = []
        refusal.onChoose = { dismissed.append($0) }
        refusal.cancelOperation(nil)
        #expect(dismissed == [0], "Esc dismisses the refusal")
        #expect(refusal.optionButtons[0].keyEquivalent == "\r")
    }

    @Test func numberedRecoveryChoicesWorkWithFullKeyboardAccessOff() throws {
        let error = NSError(domain: "test.recovery", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Choose the original show.",
            NSLocalizedRecoveryOptionsErrorKey: [
                "⌘1 Open Unsaved Copy (Created 2023-11-14; Show ID FFFFFFFF)",
                "⌘2 Show in Finder (Created date unknown; Show ID 00000000)",
                "Cancel",
            ],
            OpaqueErrorContent.requiresExplicitSelectionKey: true,
        ])
        let panel = OpaqueErrorPanel(error: error)
        var chosen: [Int] = []
        panel.onChoose = { chosen.append($0) }
        #expect(panel.content.defaultIndex == nil && panel.defaultButtonCell == nil)
        #expect(panel.optionButtons.map(\.keyEquivalent) == ["1", "2", "\u{1b}"])
        #expect(panel.optionButtons[0].keyEquivalentModifierMask == .command)
        #expect(panel.optionButtons[1].keyEquivalentModifierMask == .command)
        #expect(panel.optionButtons.prefix(2).allSatisfy { $0.title.contains("⌘") && $0.accessibilityLabel() == $0.title })

        let second = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19
        ))
        #expect(panel.performKeyEquivalent(with: second), "a key equivalent works even when Tab cannot focus buttons")
        #expect(chosen == [1], "⌘2 reveals precisely the second retained record")
        panel.cancelOperation(nil)
        #expect(chosen == [1, 2], "Esc cancels without selecting another copy")
    }

    @Test func twelveRetainedCopiesStayReachableOnNumberedKeyboardPages() throws {
        let labels = (0..<12).map { "Open Recovery Copy \($0) (Show ID \($0))" } + ["Cancel"]
        let error = NSError(domain: "test.recovery", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Choose a retained copy.",
            NSLocalizedRecoveryOptionsErrorKey: labels,
            OpaqueErrorContent.requiresExplicitSelectionKey: true,
        ])
        let panel = OpaqueErrorPanel(error: error)
        var chosen: [Int] = []
        panel.onChoose = { chosen.append($0) }
        #expect(panel.optionButtons.count == 13, "no retained copy can be capped or dropped")
        #expect(panel.optionButtons.prefix(12).filter { !$0.isHiddenOrHasHiddenAncestor }.count == 9)

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { child -> [NSButton] in
                let current = (child as? NSButton).map { [$0] } ?? []
                return current + buttons(in: child)
            }
        }
        let next = try #require(buttons(in: panel.contentView!).first { $0.title.contains("Next Recovery Page") })
        #expect(next.title.contains("⌘]") && next.keyEquivalent == "]" && next.keyEquivalentModifierMask == .command)
        let nextKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "]",
            charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30
        ))
        #expect(panel.performKeyEquivalent(with: nextKey))
        #expect(panel.optionButtons.prefix(12).filter { !$0.isHiddenOrHasHiddenAncestor }.count == 3)
        #expect(panel.optionButtons[9].title.contains("⌘1"))
        let firstOnNextPage = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "1",
            charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        #expect(panel.performKeyEquivalent(with: firstOnNextPage))
        #expect(chosen == [9], "⌘1 on page two chooses only the tenth retained copy")
        panel.cancelOperation(nil)
        #expect(chosen == [9, 12], "Esc is Cancel on every page")
    }

    // MARK: - Recovery stays the error's own (copy-only) attempter

    @Test func recoveryGoesThroughTheErrorsAttempter() {
        let attempter = Attempter()
        let error = Self.recoveryOffer(attempter: attempter)
        #expect(OpaqueErrorPresenter.attemptRecovery(from: error, optionIndex: 0))
        #expect(!OpaqueErrorPresenter.attemptRecovery(from: error, optionIndex: 1))
        #expect(attempter.chosen == [0, 1])
    }

    @Test func errorsWithoutRecoveryOptionsNeverRecover() {
        #expect(!OpaqueErrorPresenter.attemptRecovery(from: Self.refusal, optionIndex: 0))
        let attempter = Attempter()
        let noOptions = NSError(domain: "test", code: 1, userInfo: [NSRecoveryAttempterErrorKey: attempter])
        #expect(!OpaqueErrorPresenter.attemptRecovery(from: noOptions, optionIndex: 0))
        #expect(attempter.chosen.isEmpty)
    }

    /// The windowless `presentError(_:modalFor:…)` path reports back with AppKit's did-present signature.
    final class PresentDelegate: NSObject {
        var calls: [(Bool, UnsafeMutableRawPointer?)] = []
        @objc func didPresentError(withRecovery didRecover: Bool, contextInfo: UnsafeMutableRawPointer?) {
            calls.append((didRecover, contextInfo))
        }
    }

    @Test func didPresentCallbackGetsRecoveryAndContext() {
        let delegate = PresentDelegate()
        let context = UnsafeMutableRawPointer(bitPattern: 0x2A)
        let selector = #selector(PresentDelegate.didPresentError(withRecovery:contextInfo:))
        OpaqueErrorPresenter.notify(delegate, didPresent: selector, didRecover: true, contextInfo: context)
        OpaqueErrorPresenter.notify(delegate, didPresent: selector, didRecover: false, contextInfo: nil)
        OpaqueErrorPresenter.notify(delegate, didPresent: nil, didRecover: true, contextInfo: nil)
        OpaqueErrorPresenter.notify(nil, didPresent: selector, didRecover: true, contextInfo: nil)
        #expect(delegate.calls.map(\.0) == [true, false])
        #expect(delegate.calls.map(\.1) == [context, nil])
    }

    // MARK: - Routing (WaveWranglerApplication)

    private static let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

    @Test func onScreenWindowPassesThroughToAppKitsSheet() {
        let visible = OpaqueErrorPresenter.WindowState(isVisible: true, isMiniaturized: false)
        #expect(OpaqueErrorPresenter.route(for: Self.refusal, window: visible) == .sheet)
        // AppKit's sheet path applies its own cancellation handling.
        #expect(OpaqueErrorPresenter.route(for: Self.cancelled, window: visible) == .sheet)
    }

    @Test func noHiddenOrMiniaturizedWindowGetsTheOpaquePanel() {
        let states: [OpaqueErrorPresenter.WindowState?] = [
            nil,
            .init(isVisible: false, isMiniaturized: false),
            .init(isVisible: false, isMiniaturized: true),
            .init(isVisible: true, isMiniaturized: true),
        ]
        for state in states {
            #expect(OpaqueErrorPresenter.route(for: Self.refusal, window: state) == .opaquePanel, "\(String(describing: state))")
            #expect(OpaqueErrorPresenter.route(for: Self.recoveryOffer(attempter: Attempter()), window: state) == .opaquePanel)
        }
    }

    @Test func userCancelledIsNeverPresentedWithoutAWindow() {
        #expect(OpaqueErrorPresenter.route(for: Self.cancelled, window: nil) == .suppressed)
        #expect(OpaqueErrorPresenter.route(for: Self.cancelled, window: .init(isVisible: false, isMiniaturized: true)) == .suppressed)
        #expect(OpaqueErrorPresenter.route(for: NSError(domain: "other", code: NSUserCancelledError), window: nil) == .opaquePanel)
    }

    @Test func windowStateReadsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(OpaqueErrorPresenter.WindowState(window) == .init(isVisible: false, isMiniaturized: false))
        #expect(OpaqueErrorPresenter.route(for: Self.refusal, window: .init(window)) == .opaquePanel)
    }

    final class ReplacingDelegate: NSObject, NSApplicationDelegate {
        var seen: [NSError] = []
        func application(_ application: NSApplication, willPresentError error: Error) -> Error {
            seen.append(error as NSError)
            return NSError(domain: "replaced", code: 7, userInfo: [NSLocalizedDescriptionKey: "Replaced"])
        }
    }

    final class PlainDelegate: NSObject, NSApplicationDelegate {}

    @Test func willPresentHookCanReplaceTheError() {
        let delegate = ReplacingDelegate()
        let prepared = OpaqueErrorPresenter.prepare(Self.refusal, delegate: delegate, application: NSApplication.shared) as NSError
        #expect(prepared.domain == "replaced" && prepared.code == 7)
        #expect(delegate.seen.count == 1)
        #expect(OpaqueErrorContent(error: prepared).message == "Replaced", "the panel shows the delegate's error")
    }

    @Test func withoutTheHookTheErrorIsUnchanged() {
        let error = Self.recoveryOffer(attempter: Attempter())
        #expect(OpaqueErrorPresenter.prepare(error, delegate: PlainDelegate(), application: NSApplication.shared) as NSError === error)
        #expect(OpaqueErrorPresenter.prepare(error, delegate: nil, application: NSApplication.shared) as NSError === error)
    }

    // MARK: - Opaque surface and contrast

    @Test func panelIsAnOpaqueDialog() {
        let panel = OpaqueErrorPanel(error: Self.refusal)
        #expect(panel.isOpaque)
        #expect(panel.backgroundColor.alphaComponent == 1)
        #expect(panel.contentView is OpaqueBackgroundView)
        #expect(panel.contentView?.isOpaque == true)
        #expect(panel.accessibilitySubrole() == .dialog)
        #expect(panel.accessibilityIdentifier() == OpaqueErrorPanel.identifier)
        #expect(panel.title == panel.content.message, "VoiceOver announces the message as the dialog title")
        #expect(panel.messageField.textColor == .labelColor)
        #expect(panel.informativeField.textColor == .labelColor)
        #expect(panel.messageField.stringValue.contains("newer"))
    }

    /// Mini run 1 (f7729e1): the XCUITest audit flagged a decorative icon as an unlabelled image. Every image
    /// and every control in the panel must be described, so the panel has no images at all.
    @Test func panelHasNoUnlabelledImagesOrControls() {
        for error in [Self.recoveryOffer(attempter: Attempter()) as Error, Self.refusal] {
            let panel = OpaqueErrorPanel(error: error)
            var views: [NSView] = []
            func walk(_ view: NSView) { views.append(view); view.subviews.forEach(walk) }
            walk(panel.contentView!)
            #expect(!views.contains { $0 is NSImageView })
            for button in views.compactMap({ $0 as? NSButton }) { #expect(!button.title.isEmpty) }
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func textOnTheBackgroundMeetsFourPointFiveToOne(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        var ratio = 0.0
        appearance.performAsCurrentDrawingAppearance {
            let background = Self.rgba(OpaqueBackgroundView.fill)
            let text = Self.rgba(.labelColor)
            #expect(background.a == 1, "the background colour is opaque")
            ratio = Self.contrast(Self.composite(text, over: background), background)
        }
        #expect(ratio >= 4.5, "label text \(ratio):1 in \(name.rawValue)")
    }

    /// Renders the panel's content offscreen: every pixel is opaque (nothing behind the window shows through),
    /// and the strongest glyph pixels of each text reach 4.5:1 against the rendered background.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func renderedPanelIsOpaqueWithReadableText(_ name: NSAppearance.Name) throws {
        for error in [Self.recoveryOffer(attempter: Attempter()) as Error, Self.refusal] {
            let panel = OpaqueErrorPanel(error: error)
            panel.appearance = NSAppearance(named: name)
            let view = try #require(panel.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)

            var translucent = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 1 { translucent += 1 } }
            #expect(translucent == 0, "\(translucent) translucent pixels in \(name.rawValue)")

            let background = try #require(rep.colorAt(x: 2, y: 2)).usingColorSpace(.sRGB)!
            let bg: RGBA = (Double(background.redComponent), Double(background.greenComponent), Double(background.blueComponent), 1)
            for field in [panel.messageField!, panel.informativeField!] {
                let rect = field.convert(field.bounds, to: view)
                let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                // The UI audit's measure (AcceptanceAudit): glyph pixels are >= 1.5:1 against the background;
                // at least 40 of them, 75th percentile >= 4.5:1.
                var glyphs: [Double] = []
                for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    // Bitmap rows run top-down and the view isn't flipped.
                    for y in Int((view.bounds.height - rect.maxY) * scale)..<Int((view.bounds.height - rect.minY) * scale) {
                        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let ratio = Self.contrast((Double(pixel.redComponent), Double(pixel.greenComponent), Double(pixel.blueComponent), 1), bg)
                        if ratio >= 1.5 { glyphs.append(ratio) }
                    }
                }
                glyphs.sort()
                let p75 = glyphs.isEmpty ? 0 : glyphs[Int(Double(glyphs.count - 1) * 0.75)]
                #expect(glyphs.count >= 40 && p75 >= 4.5,
                        "\(field.accessibilityIdentifier()): \(glyphs.count) glyph px, p75 \(p75):1 in \(name.rawValue)")
            }
        }
    }

    // MARK: - Helpers (WCAG 2 relative luminance)

    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    static func rgba(_ color: NSColor) -> RGBA {
        let c = color.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        (top.r * top.a + bottom.r * (1 - top.a), top.g * top.a + bottom.g * (1 - top.a), top.b * top.a + bottom.b * (1 - top.a), 1)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: RGBA) -> Double { 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b) }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
