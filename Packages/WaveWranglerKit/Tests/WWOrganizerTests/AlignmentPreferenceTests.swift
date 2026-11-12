import Foundation
import Testing
import WWCore
import WWOrganizer

@Suite("App-level alignment listening default")
struct AlignmentPreferenceTests {
    @Test func cutJumpBackDefaultsPersistsAndRejectsInvalidStoredValues() throws {
        let name = "CutJumpBackPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.cutJumpBackSeconds == 0.5)
        for seconds in [0.0, 0.5, 2.75, 30] {
            preferences.cutJumpBackSeconds = seconds
            #expect(AppPreferences(defaults: defaults).cutJumpBackSeconds == seconds)
        }
        for invalid in [-1.0, 31, .infinity, .nan] {
            defaults.set(invalid, forKey: PreferenceKey.cutJumpBackSeconds)
            #expect(preferences.cutJumpBackSeconds == 0.5)
        }
        defaults.set("invalid", forKey: PreferenceKey.cutJumpBackSeconds)
        #expect(preferences.cutJumpBackSeconds == 0.5)
    }

    @Test func autoInputGainTargetPersistsAndInvalidStoredValuesUseTheEditingDefault() throws {
        let name = "AutoInputGainPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.autoInputGainTargetDBFS == -20)
        preferences.autoInputGainTargetDBFS = -23.5
        #expect(AppPreferences(defaults: defaults).autoInputGainTargetDBFS == -23.5)
        for invalid in [-100.0, 0, .infinity] {
            defaults.set(invalid, forKey: PreferenceKey.autoInputGainTargetDBFS)
            #expect(preferences.autoInputGainTargetDBFS == -20)
        }
        defaults.set("invalid", forKey: PreferenceKey.autoInputGainTargetDBFS)
        #expect(preferences.autoInputGainTargetDBFS == -20)
    }

    @Test func timelineJumpDefaultsAndChoicesRoundTripWithoutEditingEpisodeData() throws {
        let name = "TimelineJumpPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.timelineJumpInterval == .five)
        #expect(TimelineJumpInterval.allCases.map(\.rawValue) == [1, 2, 5, 10, 15, 30])
        for interval in TimelineJumpInterval.allCases {
            preferences.timelineJumpInterval = interval
            #expect(AppPreferences(defaults: defaults).timelineJumpInterval == interval)
            #expect(interval.seconds == Double(interval.rawValue))
        }
        defaults.set(7, forKey: PreferenceKey.timelineJumpSeconds)
        #expect(preferences.timelineJumpInterval == .five)
        defaults.set("invalid", forKey: PreferenceKey.timelineJumpSeconds)
        #expect(preferences.timelineJumpInterval == .five)
    }

    @Test func defaultAndAllFourChoicesRoundTripWithoutChangingEpisodeKeys() throws {
        let name = "AlignmentPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.editingPlaybackPolicy == .muteNonPrimaries)
        let episode = Episode(title: "Legacy", workspace: .init(editingPlaybackPolicy: .soloBackups))
        let bytes = try JSONEncoder().encode(episode)
        for choice in EditingPlaybackPolicy.allCases {
            preferences.editingPlaybackPolicy = choice
            #expect(AppPreferences(defaults: defaults).editingPlaybackPolicy == choice)
            #expect(try JSONDecoder().decode(Episode.self, from: bytes).workspace?.editingPlaybackPolicy == .soloBackups)
        }
        defaults.set("invalid", forKey: PreferenceKey.editingPlaybackPolicy)
        #expect(preferences.editingPlaybackPolicy == .muteNonPrimaries)
    }
}
