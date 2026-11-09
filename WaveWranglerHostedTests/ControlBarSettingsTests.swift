import Foundation
import Testing
import WWCommonEdit
@testable import WaveWrangler

@MainActor @Suite("Episode control bar preferences", .serialized)
struct ControlBarSettingsTests {
    @Test func presetsKeepCoreControlsAndBoundedOptionalOrdering() throws {
        for preset in ControlBarConfiguration.Preset.allCases {
            let value = ControlBarConfiguration.preset(preset)
            #expect(value.isValid)
            #expect(value.displayedControls(width: 0).isEmpty)
            #expect(value.displayedControls(width: 2000) == value.groups.flatMap { value.selectedControls(in: $0) })
            #expect(try JSONDecoder().decode(ControlBarConfiguration.self,
                from: JSONEncoder().encode(value)) == value)
        }
        var duplicate = ControlBarConfiguration()
        duplicate.groups = [.episode, .episode, .view]
        #expect(!duplicate.isValid)
    }

    @Test func individualControlsRemoveEmptyGroupsAndRespectSpace() {
        var value = ControlBarConfiguration()
        #expect(value.displayedControls(width: 350).contains(.zoom))
        #expect(value.displayedControls(width: 350).contains(.height))
        value.controls = [.primaryTool]
        #expect(value.selectedControls(in: .episode).isEmpty)
        #expect(value.selectedControls(in: .view).isEmpty)
        #expect(value.displayedControls(width: 50) == [.primaryTool])
        value.controls = [.height, .fit]
        #expect(value.displayedControls(width: 28, available: [.fit]) == [.fit])
        value.controls = []
        #expect(value.displayedControls(width: 2000).isEmpty)
        #expect(value.isValid)
    }

    @Test func legacyGroupPreferencesMigrateWithoutLosingClocksOrOrder() throws {
        let legacy = Data("""
        {"version":1,"groups":["tools","episode","view"],"visible":["view","episode"],
         "showsLabels":false,"primaryClock":"timeline","secondaryClock":"speaker","readout":"remaining"}
        """.utf8)
        let value = try JSONDecoder().decode(ControlBarConfiguration.self, from: legacy)
        #expect(value.version == 2)
        #expect(value.groups == [.tools, .episode, .view])
        #expect(!value.controls.contains(.primaryTool))
        #expect(!value.controls.contains(.commandTool))
        #expect(value.controls.contains(.boundaries))
        #expect(value.controls.contains(.zoom) && value.controls.contains(.height))
        #expect(!value.showsLabels && value.primaryClock == .timeline && value.secondaryClock == .speaker)
        #expect(value.readout == .remaining)
        #expect(try JSONDecoder().decode(ControlBarConfiguration.self, from: JSONEncoder().encode(value)) == value)
        for invalid in [
            String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":3"),
            String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "\"tools\",\"episode\",\"view\"", with: "\"tools\",\"tools\",\"view\""),
            String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "\"view\",\"episode\"]", with: "\"unknown\"]")
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(ControlBarConfiguration.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func fitActionsFollowTheirScalesWithoutCouplingTheirSelections() {
        var value = ControlBarConfiguration()
        value.controls = [.zoom, .fit, .height, .fillSpace, .layout]
        #expect(value.selectedControls(in: .view) == [.zoom, .fit, .height, .fillSpace, .layout])
        #expect(value.displayedControls(width: 350) == [.zoom, .fit, .height, .fillSpace])
        value.controls.remove(.fit)
        #expect(value.selectedControls(in: .view) == [.zoom, .height, .fillSpace, .layout])
        value.controls.remove(.height)
        #expect(value.selectedControls(in: .view) == [.zoom, .fillSpace, .layout])
    }

    @Test func preferencesSurviveRecreationAndCorruptionIsReported() throws {
        let name = "ww-control-bar-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults)
        first.controlBar = .preset(.review)
        first.controlBar.primaryClock = .timeline
        let second = AppSettings(defaults: defaults)
        #expect(second.controlBar == first.controlBar)
        first.controlBar.showsLabels = false
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(!second.controlBar.showsLabels, "Other windows observe app-local settings.")
        defaults.set(Data("invalid".utf8), forKey: AppSettings.controlBarKey)
        let invalid = AppSettings(defaults: defaults)
        #expect(invalid.controlBarError != nil)
        #expect(defaults.data(forKey: AppSettings.controlBarKey) == Data("invalid".utf8))
        invalid.restoreControlBar()
        #expect(invalid.controlBarError == nil)
        #expect(invalid.controlBar == ControlBarConfiguration())
        #expect(AppSettings(defaults: defaults).controlBar == ControlBarConfiguration())
    }

    @Test func clockFormattingAndParsingRemainSignedFiniteAndBounded() throws {
        #expect(EpisodeTimeDisplay.format(-1.25) == "-00:00:01.250")
        #expect(EpisodeTimeDisplay.format(3600.001) == "01:00:00.001")
        #expect(try EpisodeTimeDisplay.parse("-01:02:03.250") == -3723.25)
        #expect(try EpisodeTimeDisplay.parse("2.250") == 2.25)
        for invalid in ["NaN", "inf", "00:60:00", "49:00:00", "999999999999:00:00", "00:00:60", ""] {
            #expect(throws: (any Error).self) { try EpisodeTimeDisplay.parse(invalid) }
        }
    }
}
