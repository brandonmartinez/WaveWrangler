import Testing
import WWCore

@Suite("Independent Solo and Mute precedence")
struct EpisodePlaybackStateTests {
    private let speakerA = SpeakerID()
    private let speakerB = SpeakerID()
    private let recorderA = RecorderGroup(name: "A")
    private let recorderB = RecorderGroup(name: "B")
    private let sourceA = SourceID()
    private let sourceB = SourceID()
    private let sourceC = SourceID()
    private let episodeID = EpisodeID()

    private var episode: Episode {
        Episode(id: episodeID, title: "Synthetic", recorderGroups: [recorderA, recorderB], sources: [
            SourceRecord(id: sourceA, displayNameHint: "A", placement: .init(recorderGroupID: recorderA.id)),
            SourceRecord(id: sourceB, displayNameHint: "B", placement: .init(recorderGroupID: recorderA.id)),
            SourceRecord(id: sourceC, displayNameHint: "C", placement: .init(recorderGroupID: recorderB.id)),
        ], speakerAssignments: [
            .init(speakerID: speakerA, primary: .init(sourceID: sourceA, statedChannel: 0),
                  backups: [.init(sourceID: sourceC, statedChannel: 0)]),
            .init(speakerID: speakerB, primary: .init(sourceID: sourceB, statedChannel: 0),
                  backups: [.init(sourceID: sourceC, statedChannel: 1)]),
        ])
    }

    @Test func solosAreAdditiveAcrossOverlappingMembershipAndAnyMuteWins() {
        var playback = EpisodePlaybackState()
        #expect(playback.audibleSources(in: episode) == [sourceA, sourceB, sourceC])
        playback.setSoloed(true, scope: .speaker(speakerA))
        #expect(playback.audibleSources(in: episode) == [sourceA, sourceC])
        playback.setSoloed(true, scope: .recorder(recorderA.id))
        #expect(playback.audibleSources(in: episode) == [sourceA, sourceB, sourceC])
        playback.setMuted(true, scope: .source(sourceB))
        playback.setMuted(true, scope: .recorder(recorderB.id))
        #expect(playback.audibleSources(in: episode) == [sourceA])
        playback.setMuted(true, scope: .speaker(speakerA))
        #expect(playback.audibleSources(in: episode).isEmpty)
        playback.setSoloed(false, scope: .speaker(speakerA))
        #expect(playback.soloed == [.recorder(recorderA.id)])
        #expect(playback.muted.contains(.source(sourceB)))
    }

    @Test func groupTogglesNeverEraseIndividualSettingsAndSharedFilesStaySingle() {
        var playback = EpisodePlaybackState(muted: [.source(sourceA)], soloed: [.source(sourceC)])
        playback.setMuted(true, scope: .recorder(recorderA.id))
        playback.setMuted(false, scope: .recorder(recorderA.id))
        #expect(playback.muted == [.source(sourceA)])
        #expect(playback.soloed == [.source(sourceC)])
        #expect(playback.audibleSources(in: episode) == [sourceC])
        playback.setMuted(true, scope: .speaker(speakerB))
        #expect(playback.audibleSources(in: episode).isEmpty, "A shared file is muted by either assigned speaker's Mute.")
    }

    @Test func namedPoliciesDoNotChangeRolesAndPreserveExplicitMutes() throws {
        let original = episode
        let playback = EpisodePlaybackState(muted: [.source(sourceA)], soloed: [.recorder(recorderB.id)])
        #expect(try playback.applying(.keepChoices, in: original) == playback)
        let primary = try playback.applying(.soloPrimaries, in: original)
        #expect(primary.soloed == [.source(sourceA), .source(sourceB)])
        #expect(primary.muted == playback.muted)
        #expect(primary.audibleSources(in: original) == [sourceB])
        #expect(try playback.applying(.soloBackups, in: original).soloed == [.source(sourceC)])
        #expect(try playback.applying(.muteNonPrimaries, in: original).muted == [.source(sourceA), .source(sourceC)])
        #expect(episode == original)
    }

    @Test func anEmptySoloTargetIsRefusedInsteadOfEnablingEveryTrack() {
        let playback = EpisodePlaybackState()
        let empty = Episode(title: "Empty")
        #expect(!playback.canApply(.soloPrimaries, in: empty))
        #expect(!playback.canApply(.soloBackups, in: empty))
        #expect(throws: DomainError.self) { try playback.applying(.soloPrimaries, in: empty) }
        #expect(throws: DomainError.self) { try playback.applying(.soloBackups, in: empty) }
        var allPrimary = episode
        allPrimary.sources.removeAll { $0.id == sourceC }
        #expect(!playback.canApply(.soloBackups, in: allPrimary))
        #expect(throws: DomainError.self) { try playback.applying(.soloBackups, in: allPrimary) }
    }

    @Test func deletedScopesArePrunedWithoutDiscardingSurvivingChoices() {
        var playback = EpisodePlaybackState(muted: [.source(sourceA), .source(SourceID())],
            soloed: [.speaker(speakerA), .recorder(RecorderGroupID())])
        playback.retainScopes(in: episode)
        #expect(playback.muted == [.source(sourceA)])
        #expect(playback.soloed == [.speaker(speakerA)])
        #expect(!playback.isAudible(SourceID(), in: episode))
    }
}
