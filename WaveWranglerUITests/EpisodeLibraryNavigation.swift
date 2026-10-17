import XCTest

@MainActor
enum EpisodeLibraryNavigation {
    static func browseCurrentShow(in app: XCUIApplication) {
        let library = app.buttons["ww.show.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.library.episodes"].waitForExistence(timeout: 10))
    }

    static func openEpisode(
        containing title: String, in app: XCUIApplication, destination: String,
        closePrevious: Bool = true
    ) {
        let editors = app.windows.matching(identifier: "ww.show.window")
        let previousTitle = closePrevious ? editors.firstMatch.title : nil
        browseCurrentShow(in: app)
        if let previousTitle {
            // AX appends the subtitle with a dash; the Window menu puts it in parentheses.
            let menuTitle = previousTitle.components(separatedBy: " \u{2013} ").first ?? previousTitle
            app.menuBars.menuBarItems["Window"].click()
            let item = app.menuBars.menuItems.matching(
                NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", menuTitle, menuTitle)
            ).firstMatch
            XCTAssertTrue(item.exists, "Window menu is missing \(previousTitle): \(app.debugDescription)")
            item.click()
            app.typeKey("w", modifierFlags: .command)
            let previous = editors.matching(NSPredicate(format: "title == %@", previousTitle)).firstMatch
            XCTAssertTrue(previous.waitForNonExistence(timeout: 5))
        }
        let episode = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "ww.show.sidebar.episode.", title, title
        )).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.click()
        app.buttons["ww.library.episode.open"].click()
        let window = app.windows.matching(identifier: "ww.show.window")
            .matching(NSPredicate(format: "title CONTAINS %@", title)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey(destination, modifierFlags: .command)
    }
}
