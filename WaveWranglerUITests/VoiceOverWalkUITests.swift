import AppKit
import XCTest

/// M1-A11Y-002 VoiceOver walk (grant B: temporary VoiceOver). Requires VoiceOver to be ON (the harness turns
/// it on with ⌘F5 and off afterwards); skips otherwise. Each step drives the app with the keyboard commands
/// a VoiceOver user uses (VoiceOver follows keyboard focus) or a VO command (⌃⌥ + key), waits, and records
/// what VoiceOver actually spoke, read from VoiceOver's caption panel — never inferred from the AX tree.
/// Results are judged per task in docs/m1/evidence/ww-007-accessibility-responsiveness.md.
@MainActor
final class VoiceOverWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private let voiceOver = XCUIApplication(bundleIdentifier: "com.apple.VoiceOver")
    private var transcript: [[String: String]] = []
    private var lastCaption = ""

    override func setUp() async throws {
        continueAfterFailure = true
        guard voiceOver.state == .runningForeground || voiceOver.state == .runningBackground else {
            throw XCTSkip("VoiceOver is not running; the harness turns it on (grant B) before this suite")
        }
    }

    override func tearDown() async throws {
        Acceptance.writeEvidence("a11y002-\(name.replacingOccurrences(of: " ", with: "_"))", ["revision": Acceptance.revision(), "steps": transcript], test: self)
        if let app, app.state != .notRunning { app.terminate() }
    }

    // MARK: - Walks

    func testLibraryCollectionsAndSettings() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        step("T05", "Library opens (focus on sidebar)", nil)
        step("T05", "↓ Recent", .downArrow)
        step("T22", "↓ Unavailable", .downArrow)
        step("T22", "Tab to entries", "\t")
        step("T22", "↓ first unavailable entry", .downArrow)
        step("T22", "VO-→ read next item (status cell)", .rightArrow, [.control, .option])
        step("T22", "VO-→ read next item", .rightArrow, [.control, .option])
        step("T04", "⇧Tab back to sidebar", "\t", .shift)
        step("T04", "↓ Synthetic Collection 1", .downArrow)
        step("T04", "⌥⌘↓ Move Collection Down", .downArrow, [.command, .option])
        step("T04", "⌘Z undo move", "z", .command)
        step("T04", "⌫ Delete collection (confirmation)", .delete)
        step("T04", "Esc cancels", .escape)
        step("T14", "⌘, Settings", ",", .command)
        step("T14", "Tab to autosave switch", "\t")
        step("T14", "Tab", "\t")
        step("T25", "Tab", "\t")
        step("T25", "Tab", "\t")
        step("T19", "⌘W close settings", "w", .command)
    }

    func testShowEpisodeMetadataSaveAndBlocked() throws {
        launch(["-WWUITestLibraryFixture", "empty", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "1",
                "-WWUITestAutosave", "OFF"])
        step("T01", "Show window opens", nil)
        step("T02", "⇧⌘N New Episode (inline rename)", "n", [.command, .shift])
        step("T02", "type title + Return", "Pilot\r", text: true)
        step("T03", "⌘I Episode Info (Title)", "i", .command)
        step("T03", "Tab to Number", "\t")
        step("T03", "type invalid number", "abc", text: true)
        step("T03", "VO-→ read error", .rightArrow, [.control, .option])
        step("T03", "fix number", "12\t", selectAll: true)
        step("T15", "⌘S Save (announcement)", "s", .command)
        step("T15", "VO-→ (next)", .rightArrow, [.control, .option])
        step("T06", "⌘2 Alignment (blocked)", "2", .command)
        step("T06", "VO-→ read heading", .rightArrow, [.control, .option])
        step("T06", "⌘1 back to Setup", "1", .command)
        step("T24", "Edit menu undo name (⌘Z)", "z", .command)
        step("T23", "⌘W close with unsaved changes", "w", .command)
        step("T23", "VO-→ read sheet", .rightArrow, [.control, .option])
        step("T23", "Esc cancel", .escape)
    }

    func testSetupImportGroupingSpeakersRelinkDownloads() throws {
        launch(["-WWUITestOpenShow", "Setup Fixture", "-WWUITestShowEpisodes", "1"], environment: ["WW_SETUP_ENGINE": "fixture-states"])
        step("T07", "⌘1 Setup", "1", .command)
        step("T07", "⇧⌘I Import Sources (review sheet)", "i", [.command, .shift])
        step("T07", "↓ next candidate", .downArrow)
        step("T07", "Space toggles Include", " ")
        step("T07", "Space toggles back", " ")
        step("T07", "VO-→ next", .rightArrow, [.control, .option])
        step("T07", "Return Import", .return)
        step("T08", "↓ in Sources", .downArrow)
        step("T08", "↓", .downArrow)
        step("T13", "⌃⌘I inspector", "i", [.command, .control])
        step("T13", "VO-→", .rightArrow, [.control, .option])
        step("T13", "VO-→", .rightArrow, [.control, .option])
        step("T13", "VO-→", .rightArrow, [.control, .option])
        step("T11", "↓ next source", .downArrow)
        step("T11", "↓ next source", .downArrow)
        step("T18", "↓ next source", .downArrow)
        step("T29", "↓ next source", .downArrow)
        step("T12", "↓ next source", .downArrow)
        step("T10", "Tab to Speakers", "\t")
        step("T10", "↓", .downArrow)
    }

    // MARK: - Steps

    private func launch(_ arguments: [String], environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES"] + arguments
        app.launchEnvironment = environment
        app.launch()
        app.activate()
        Thread.sleep(forTimeInterval: 3)
    }

    private func step(_ task: String, _ action: String, _ key: XCUIKeyboardKey?, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        if let key { app.typeKey(key, modifierFlags: modifiers) }
        capture(task, action)
    }

    private func step(_ task: String, _ action: String, _ key: String, _ modifiers: XCUIElement.KeyModifierFlags = [], text: Bool = false, selectAll: Bool = false) {
        if selectAll { app.typeKey("a", modifierFlags: .command) }
        if text { app.typeText(key) } else { app.typeKey(key, modifierFlags: modifiers) }
        capture(task, action)
    }

    private func capture(_ task: String, _ action: String) {
        Thread.sleep(forTimeInterval: 2.0)
        let caption = captionText()
        // The caption panel's own pixels too (what a sighted reviewer would see), cropped to VoiceOver's windows.
        let panel = voiceOver.windows.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
        let shotName = "vo-\(transcript.count)-\(task).png"
        if !panel.isNull, let cg = XCUIScreen.main.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = CGFloat(cg.width) / XCUIScreen.main.screenshot().image.size.width
            let rect = CGRect(x: panel.minX * scale, y: panel.minY * scale, width: panel.width * scale, height: panel.height * scale).integral
            if let crop = cg.cropping(to: rect), let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                Acceptance.attach(self, png: png, name: shotName)
            }
        }
        transcript.append(["task": task, "action": action, "spoken": caption, "changed": caption == lastCaption ? "no" : "yes", "captionCrop": shotName])
        print("[vo] \(task) | \(action) | \(caption)")
        lastCaption = caption
    }

    /// The text currently shown in VoiceOver's caption panel.
    private func captionText() -> String {
        let texts = voiceOver.descendants(matching: .staticText).allElementsBoundByIndex.compactMap { element -> String? in
            let value = (element.value as? String) ?? element.label
            return value.isEmpty ? nil : value
        }
        if !texts.isEmpty { return texts.joined(separator: " ¦ ") }
        let any = voiceOver.descendants(matching: .any).allElementsBoundByIndex.compactMap { element -> String? in
            let value = (element.value as? String) ?? element.label
            return value.isEmpty ? nil : value
        }
        return any.joined(separator: " ¦ ")
    }
}
