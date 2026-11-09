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
            #expect(value.displayedGroups(width: 500).isEmpty)
            #expect(value.displayedGroups(width: 2000) == value.groups.filter { value.visible.contains($0) })
            #expect(try JSONDecoder().decode(ControlBarConfiguration.self,
                from: JSONEncoder().encode(value)) == value)
        }
        var duplicate = ControlBarConfiguration()
        duplicate.groups = [.episode, .episode, .view]
        #expect(!duplicate.isValid)
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
