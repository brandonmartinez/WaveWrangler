import AppKit
import SwiftUI

@MainActor
struct NativeTimelineSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let identifier: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> Slider {
        let slider = Slider(
            value: value, minValue: range.lowerBound, maxValue: range.upperBound,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        updateNSView(slider, context: context)
        return slider
    }

    func updateNSView(_ slider: Slider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        slider.editingChanged = onEditingChanged
        // Keep AppKit's native slider tree, including its value-bearing thumb.
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityIdentifier(identifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) { self.value = value }

        @objc
        func changed(_ slider: Slider) {
            let standalone = !slider.isTrackingMouse
            if standalone { slider.editingChanged(true) }
            value.wrappedValue = slider.doubleValue
            if standalone { slider.editingChanged(false) }
        }
    }

    @MainActor
    final class Slider: NSSlider {
        var editingChanged: (Bool) -> Void = { _ in }
        private(set) var isTrackingMouse = false

        override var acceptsFirstResponder: Bool { isEnabled }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            window?.makeFirstResponder(self)
            isTrackingMouse = true
            editingChanged(true)
            defer {
                isTrackingMouse = false
                editingChanged(false)
            }
            super.mouseDown(with: event)
        }
    }
}
