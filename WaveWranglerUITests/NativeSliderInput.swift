import XCTest

@MainActor
extension XCUIElement {
    func dragHorizontalSliderToMaximum() {
        // XCTest's normalized adjustment can stop inside AppKit's track padding.
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0))
        start.click(forDuration: 0.1, thenDragTo: end)
    }
}
