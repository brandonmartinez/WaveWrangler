import AppKit
import OSLog
import WWOrganizer

@MainActor
final class NativeSaveStatusControl: NSStackView {
    let button = NSButton()
    let spinner = NSProgressIndicator()
    private var activate: () -> Void = {}
    private var focusRequest = 0
    private static let log = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "save-status.focus")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        detachesHiddenViews = true
        setAccessibilityElement(false)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.setAccessibilityElement(false)
        spinner.isHidden = true
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(pressed)
        button.setAccessibilityIdentifier("ww.show.saveStatus")
        addArrangedSubview(spinner)
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(
        presentation: SaveStatusPresentation, pointSize: CGFloat,
        focusRequest: Int, activate: @escaping () -> Void
    ) {
        self.activate = activate
        button.title = presentation.itemText
        button.font = .systemFont(ofSize: pointSize)
        button.toolTip = presentation.popoverText
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.setAccessibilityValue(presentation.accessibilityValue)
        button.setAccessibilityHelp(presentation.accessibilityHint)
        if let symbol = presentation.symbolName {
            let color: NSColor = switch presentation.tint {
            case .none: .secondaryLabelColor
            case .attention: .systemOrange
            case .failed: .systemRed
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color]))
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        } else {
            button.image = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
        invalidateIntrinsicContentSize()
        guard focusRequest > self.focusRequest else { return }
        self.focusRequest = focusRequest
        // The toolbar must finish updating before AppKit receives its concrete button responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusRequest == focusRequest,
                  let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return }
            if !window.makeFirstResponder(self.button) {
                Self.log.error("Could not restore keyboard focus to the save-status button.")
            }
        }
    }

    @objc private func pressed() { activate() }
}
