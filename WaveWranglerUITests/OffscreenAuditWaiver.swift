import XCTest

/// "Not on screen" audit waiver, shared by every UI-test suite's accessibility audit (coordinator decision on
/// #113). An element whose frame has NO intersection with any of the app's window frames can't be seen or
/// measured (the audit samples pixels that were never drawn, e.g. text of a partly visible last row that lies
/// wholly below the window edge). Partial intersection never qualifies. Each use is logged with the element frame
/// and the window rects, and counted against a pinned maximum per audit.
enum OffscreenAuditWaiver {
    /// At most one partly visible row's cells per audit.
    static let pinnedMaximumPerAudit = 5

    static let rationale = "not on screen: no intersection with any window's content rect"

    /// The app's window frames at audit time (call before `performAccessibilityAudit`).
    static func windowRects(of app: XCUIApplication) -> [CGRect] {
        app.windows.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
    }

    /// The waiver log line when `element` lies wholly outside every window rect; nil otherwise.
    static func waiver(for element: XCUIElement?, windowRects: [CGRect]) -> String? {
        guard let element, !windowRects.isEmpty else { return nil }
        let frame = element.frame
        guard !frame.isEmpty, !windowRects.contains(where: { $0.intersects(frame) }) else { return nil }
        return "\(rationale) — element \(frame), windows \(windowRects)"
    }

    /// Fails the test when an audit used the waiver more often than pinned.
    static func assertWithinPin(_ count: Int, surface: String, file: StaticString = #filePath, line: UInt = #line) {
        print("AUDIT \(surface) rule notOnScreen: \(count) (pinned ≤ \(pinnedMaximumPerAudit))")
        XCTAssertLessThanOrEqual(count, pinnedMaximumPerAudit, "\(surface): too many not-on-screen waivers", file: file, line: line)
    }
}
