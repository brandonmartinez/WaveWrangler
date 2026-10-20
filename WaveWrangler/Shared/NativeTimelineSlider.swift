import AppKit
import SwiftUI

struct NativeTimelineSlider: View {
    let title: String
    let identifier: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var editingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fixedSize()
            Control(title: title, identifier: identifier, value: $value,
                    bounds: bounds, editingChanged: editingChanged)
                .frame(minWidth: 40)
        }
    }

    private struct Control: NSViewRepresentable {
        let title: String
        let identifier: String
        @Binding var value: Double
        let bounds: ClosedRange<Double>
        let editingChanged: (Bool) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> Slider {
            let slider = Slider(frame: .zero)
            slider.controlSize = .small
            slider.isContinuous = true
            slider.target = context.coordinator
            slider.action = #selector(Coordinator.changeValue(_:))
            slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return slider
        }

        func updateNSView(_ slider: Slider, context: Context) {
            context.coordinator.control = self
            slider.minValue = bounds.lowerBound
            slider.maxValue = bounds.upperBound
            slider.doubleValue = value
            slider.isEnabled = context.environment.isEnabled
            slider.editingChanged = editingChanged
            slider.setAccessibilityLabel(title)
            slider.setAccessibilityIdentifier(identifier)
        }

        @MainActor
        final class Coordinator: NSObject {
            var control: Control
            init(_ control: Control) { self.control = control }

            @objc func changeValue(_ sender: Slider) {
                if !sender.isTracking { control.editingChanged(true) }
                control.value = sender.doubleValue
                if !sender.isTracking { control.editingChanged(false) }
            }
        }

        @MainActor
        final class Slider: NSSlider {
            var editingChanged: ((Bool) -> Void)?
            private(set) var isTracking = false

            override func mouseDown(with event: NSEvent) {
                isTracking = true
                editingChanged?(true)
                defer {
                    isTracking = false
                    editingChanged?(false)
                }
                super.mouseDown(with: event)
            }

            override func accessibilityChildren() -> [Any]? {
                let children = super.accessibilityChildren()
                for case let child as any NSAccessibilityProtocol in children ?? [] {
                    child.setAccessibilityLabel(accessibilityLabel())
                }
                return children
            }
        }
    }
}
