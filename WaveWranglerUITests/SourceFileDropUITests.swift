import AppKit
import XCTest

@MainActor
final class SourceFileDropUITests: XCTestCase {
    func testFinderDropsReachTheEmptyOverlayRowsAndBlankSourcesArea() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appending(path: "WW-File-Drops-\(UUID())")
        let child = folder.appending(path: "Folder recording", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "recording-a.wav")
        let second = folder.appending(path: "recording-b.wav")
        let third = child.appending(path: "recording-c.wav")
        let bytes = Self.wave()
        for url in [first, second, third] { try bytes.write(to: url) }
        let app = XCUIApplication()
        app.launchEnvironment.removeValue(forKey: "WW_SETUP_ENGINE")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestResetSourceAccess", "YES",
            "-WWUITestOpenShow", "Native file drops", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        app.descendants(matching: .any)["ww.show.views"].click()
        app.menuItems["Recordings & Speakers…"].click()
        let outline = app.outlines["ww.setup.sources"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(NSWorkspace.shared.open(folder))
        finder.activate()
        let window = finder.windows[folder.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        finder.typeKey("1", modifierFlags: .command)
        if window.frame.width > 760 || window.frame.height > 540 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(
                dx: min(0, 700 - window.frame.width), dy: min(0, 500 - window.frame.height))))
        }
        let mainFrame = app.windows["ww.show.window"].frame
        let oldFrame = window.frame
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 8))
        title.click(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(
            dx: mainFrame.maxX - oldFrame.maxX, dy: mainFrame.minY + 40 - oldFrame.minY)))

        func finderItem(_ name: String) -> XCUIElement {
            window.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR value == %@", name, name)).firstMatch
        }
        func drop(_ name: String, at destination: XCUICoordinate) {
            finder.activate()
            let item = finderItem(name)
            XCTAssertTrue(item.waitForExistence(timeout: 5), finder.debugDescription)
            item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: destination)
            app.activate()
            let confirm = app.buttons["ww.import.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(confirm.label, "Import 1")
            confirm.click()
            XCTAssertTrue(app.descendants(matching: .any)["ww.import.review"].waitForNonExistence(timeout: 10))
        }
        let empty = app.descendants(matching: .any)["ww.setup.empty"]
        XCTAssertTrue(empty.exists)
        drop(first.lastPathComponent, at: empty.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        let row = outline.outlineRows.containing(NSPredicate(
            format: "identifier BEGINSWITH 'ww.setup.source.' AND (label == %@ OR value == %@)",
            first.lastPathComponent, first.lastPathComponent)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        drop(second.lastPathComponent, at: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        let viewport = app.scrollViews.containing(.outline, identifier: "ww.setup.sources").firstMatch
        XCTAssertTrue(viewport.exists)
        drop(child.lastPathComponent, at: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.85)))
        XCTAssertTrue(outline.outlineRows.containing(NSPredicate(
            format: "identifier BEGINSWITH 'ww.setup.source.' AND (label == %@ OR value == %@)",
            third.lastPathComponent, third.lastPathComponent)).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ww.setup.authorizeOriginals"].exists)
        for url in [first, second, third] { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    private static func wave() -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let frames = 4800, size = frames * 2
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + size))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1)); put(UInt32(48_000)); put(UInt32(96_000))
        put(UInt16(2)); put(UInt16(16)); data.append(contentsOf: "data".utf8); put(UInt32(size))
        for frame in 0..<frames { put(Int16(frame % 1000 - 500)) }
        return data
    }
}
