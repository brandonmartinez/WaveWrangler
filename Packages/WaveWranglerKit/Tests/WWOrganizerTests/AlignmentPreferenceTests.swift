import Foundation
import Testing
import WWCore
import WWOrganizer

@Suite("App-level alignment listening default")
struct AlignmentPreferenceTests {
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
