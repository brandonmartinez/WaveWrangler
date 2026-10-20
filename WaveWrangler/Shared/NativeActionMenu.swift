import AppKit
import SwiftUI

@MainActor
struct NativeActionMenu: NSViewRepresentable {
    struct Action {
        let title: String
        var symbol: String? = nil
        var isSelected = false
        let perform: @MainActor () -> Void
    }

    let label: String
    let symbol: String
    let identifier: String
    var value: String? = nil
    var prefix: String? = nil
    var isEnabled = true
    let actions: [Action]

    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.bezelStyle = .rounded
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        let menu = NSMenu()
        let heading = NSMenuItem(title: prefix ?? value ?? label, action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(heading)
        for action in actions {
            let target = ActionTarget(action.perform)
            let item = NSMenuItem(title: action.title, action: #selector(ActionTarget.perform(_:)), keyEquivalent: "")
            if let symbol = action.symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            item.state = action.isSelected ? .on : .off
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        button.imagePosition = prefix == nil ? .imageOnly : .imageLeading
        button.menu = menu
        button.selectionValue = value
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }

    @MainActor
    final class Button: NSPopUpButton {
        var selectionValue: String?

        override func accessibilityValue() -> Any? {
            selectionValue ?? super.accessibilityValue()
        }
    }

    @MainActor
    private final class ActionTarget: NSObject {
        let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) { self.action = action }

        @objc func perform(_ sender: NSMenuItem) { action() }
    }
}
