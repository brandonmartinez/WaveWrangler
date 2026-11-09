import XCTest

@MainActor
func openTimelineMore(in app: XCUIApplication) {
    let overflow = app.scrollViews["ww.controlBar.overflow"]
    if !overflow.exists { app.buttons["ww.controlBar.more"].click() }
    XCTAssertTrue(overflow.waitForExistence(timeout: 5), app.debugDescription)
}

@MainActor
func closeTimelineMore(in app: XCUIApplication) {
    let overflow = app.scrollViews["ww.controlBar.overflow"]
    if overflow.exists {
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overflow.waitForNonExistence(timeout: 5), app.debugDescription)
    }
}

@MainActor
func revealTimelineControl(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    let overflow = app.scrollViews["ww.controlBar.overflow"]
    let identifier = element.exists ? element.identifier : ""
    let isTimelineControl = identifier.isEmpty
        || (identifier.hasPrefix("alignment.waveforms.")
            && !identifier.hasPrefix("alignment.waveforms.track."))
        || identifier.hasPrefix("ww.controlBar.")
        || identifier.hasPrefix("ww.audioWorkspace.")
    if !isTimelineControl {
        closeTimelineMore(in: app)
        return element.exists && element.isHittable
    }
    if overflow.exists {
        if element.exists, overflow.descendants(matching: .any)
            .matching(identifier: element.identifier).firstMatch.exists {
            return element.isHittable
        }
        closeTimelineMore(in: app)
    }
    if element.exists && element.isHittable { return true }
    openTimelineMore(in: app)
    if element.exists && element.isHittable { return true }
    closeTimelineMore(in: app)
    return false
}

@MainActor
func selectSourceAudition(in app: XCUIApplication) {
    closeTimelineMore(in: app)
    app.descendants(matching: .any)["ww.controlBar.listeningMode"].click()
    app.menuItems["ww.audioWorkspace.sourceAudition"].click()
}

@MainActor
func openTimelineAdd(in app: XCUIApplication) {
    let add = app.descendants(matching: .any)["ww.controlBar.add"]
    if !add.exists || !add.isHittable { openTimelineMore(in: app) }
    add.click()
}

@MainActor
func chooseAddAudio(in app: XCUIApplication) {
    openTimelineAdd(in: app)
    app.menuItems["ww.audioWorkspace.addAudio"].click()
}

@MainActor
func chooseAddRecordings(in app: XCUIApplication) {
    openTimelineAdd(in: app)
    app.menuItems["ww.audioWorkspace.add"].click()
}

@MainActor
func setTimelineFollowPlayhead(_ enabled: Bool, in app: XCUIApplication) {
    let button = app.buttons["alignment.waveforms.followPlayhead"]
    if button.exists {
        closeTimelineMore(in: app)
        if button.value as? String != (enabled ? "On" : "Off") { button.click() }
        XCTAssertEqual(button.value as? String, enabled ? "On" : "Off")
    } else {
        openTimelineMore(in: app)
        let checkbox = app.scrollViews["ww.controlBar.overflow"].checkBoxes["Follow Playhead"]
        if String(describing: checkbox.value ?? "") != (enabled ? "1" : "0") { checkbox.click() }
        XCTAssertEqual(String(describing: checkbox.value ?? ""), enabled ? "1" : "0")
        closeTimelineMore(in: app)
    }
}

@MainActor
func clickTimelineButton(_ identifier: String, in app: XCUIApplication) {
    let button = app.buttons[identifier]
    if !button.exists || !button.isHittable { openTimelineMore(in: app) }
    button.click()
    closeTimelineMore(in: app)
}

@MainActor
func adjustTimelineSlider(_ identifier: String, to position: CGFloat, in app: XCUIApplication) {
    openTimelineMore(in: app)
    app.sliders[identifier].adjust(toNormalizedSliderPosition: position)
    closeTimelineMore(in: app)
}

@MainActor
func playProductionMix(in app: XCUIApplication) {
    app.descendants(matching: .any)["ww.controlBar.listeningMode"].click()
    app.menuItems["ww.audioWorkspace.playMix"].click()
    app.buttons["alignment.waveforms.transport.play"].click()
}

@MainActor
func timelineClockSeconds(_ field: XCUIElement) -> Double? {
    guard let value = field.value as? String else { return nil }
    let negative = value.hasPrefix("-")
    let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .split(separator: ":").compactMap { Double($0) }
    guard parts.count == 3 else { return nil }
    return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * (negative ? -1 : 1)
}

@MainActor
func selectTimelineLayout(_ title: String, in app: XCUIApplication) {
    let picker = app.popUpButtons["alignment.waveforms.layout"]
    if !picker.exists || !picker.isHittable { openTimelineMore(in: app) }
    XCTAssertTrue(picker.waitForExistence(timeout: 10) && picker.isHittable, app.debugDescription)
    picker.click()
    let option = picker.menuItems[title]
    XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
    option.click()
    XCTAssertEqual(picker.value as? String, title)
    closeTimelineMore(in: app)
}
