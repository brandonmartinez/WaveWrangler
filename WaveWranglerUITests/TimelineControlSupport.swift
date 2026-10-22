import XCTest

@MainActor
func selectTimelineLayout(_ title: String, in app: XCUIApplication) {
    let picker = app.popUpButtons["alignment.waveforms.layout"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10) && picker.isHittable, app.debugDescription)
    picker.click()
    let option = picker.menuItems[title]
    XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
    option.click()
    XCTAssertEqual(picker.value as? String, title)
}
