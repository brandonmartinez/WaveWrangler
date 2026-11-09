import Foundation
import Testing
import WWCore
@testable import WWCommonEdit

@Suite("Episode boundaries and presentation clocks")
struct EpisodeProductionProjectionTests {
    let rate = AudioArrangement.frameRate

    func projection(_ episode: Episode, coverage: Range<Int64>? = 0..<4_800_000) throws -> EpisodeProductionProjection {
        try .init(episode: episode, composition: ProgramTimeline(episode: episode, dialogueFrames: coverage).composition())
    }

    func speakerEpisode(_ fixture: ProgramFixture) -> Episode {
        var episode = fixture.episode()
        episode.cleanup?.workingRange = .init(alignmentRevision: 1, tracksIn: 2, tracksOut: 8)
        return episode
    }

    @Test func automaticBoundsUseSpeakerMarkersWithoutTrimmingTheMediaHull() throws {
        let f = try ProgramFixture(), episode = speakerEpisode(f)
        let value = try projection(episode)
        #expect(value.episodeFrames == 2 * rate..<8 * rate)
        #expect(value.speakerAlignedFrames == 2 * rate..<8 * rate)
        #expect(value.composition.programFrames == f.coverage)
        #expect(!value.restrictSpeech)
        #expect(value.speechGain(atProgramFrame: 0) == 1)
        #expect(try projection(f.episode()).episodeFrames == f.coverage)
    }

    @Test func musicExtendsBothEdgesRegardlessOfFaderGain() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        episode.audioArrangement?.clips = [
            f.clip(.absolute(frame: -2 * rate), duration: 4 * rate),
            f.clip(.absolute(frame: 7 * rate), duration: 4 * rate),
        ]
        let expected = try projection(episode).episodeFrames
        #expect(expected == -2 * rate..<11 * rate)
        episode.mix = .init(audioTracks: [.init(track: f.track.id, gainDB: -96)])
        #expect(try projection(episode).episodeFrames == expected)
    }

    @Test func insertionEdgesRespectSpeakerSampleAffinityAndArrangedSilence() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        episode.audioArrangement?.insertionRegions = [
            .init(anchor: .dialogue(try f.anchor(2 * rate)), durationFrames: rate),
            .init(anchor: .dialogue(try f.anchor(8 * rate)), durationFrames: rate),
        ]
        let value = try projection(episode)
        #expect(value.speakerProgramFrames == 3 * rate..<9 * rate)
        #expect(value.episodeFrames == 2 * rate..<10 * rate)
        #expect(try value.clockFrame(atProgramFrame: 2 * rate, clock: .speaker) == nil)
        #expect(try value.clockFrame(atProgramFrame: 3 * rate, clock: .speaker) == 0)
    }

    @Test func clocksExcludeCutsAndMusicOnlyTimeWithoutRebasingTheTimeline() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        episode.cleanup?.manualCuts = [f.cut(4 * rate, 5 * rate)]
        episode.audioArrangement?.insertionRegions = [
            .init(anchor: .dialogue(try f.anchor(3 * rate)), durationFrames: 2 * rate)
        ]
        let value = try projection(episode)
        #expect(try value.clockFrame(atProgramFrame: rate, clock: .episode) == -rate)
        #expect(try value.clockFrame(atProgramFrame: 6 * rate, clock: .episode) == 4 * rate)
        #expect(try value.clockFrame(atProgramFrame: 6 * rate, clock: .speaker) == 2 * rate)
        #expect(try value.clockFrame(atProgramFrame: 6 * rate, clock: .timeline) == 6 * rate)
        #expect(try value.clockFrame(atProgramFrame: 4 * rate, clock: .speaker) == nil)
        for frame in stride(from: Int64(0), to: 12 * rate, by: Int(rate / 4)) {
            for clock in EpisodeClock.allCases {
                if let displayed = try value.clockFrame(atProgramFrame: frame, clock: clock) {
                    #expect(try value.programFrame(atClockFrame: displayed, clock: clock) == frame)
                }
            }
        }
    }

    @Test func manualEdgesReusePinnedDialogueAndInsertionAnchors() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        let region = AudioInsertionRegion(anchor: .dialogue(try f.anchor(3 * rate)), durationFrames: 2 * rate)
        episode.audioArrangement?.insertionRegions = [region]
        episode.productionRange = .init(start: .insertion(region: region.id, offsetFrames: rate),
                                        end: .absolute(frame: 12 * rate))
        #expect(try projection(episode).episodeFrames == 4 * rate..<12 * rate)
        episode.productionRange?.start = .dialogue(try f.anchor(2 * rate))
        episode.cleanup?.manualCuts = [f.cut(0, rate)]
        #expect(try projection(episode).episodeFrames == rate..<12 * rate)
        episode.productionRange?.start = nil
        #expect(try projection(episode).episodeFrames == rate..<12 * rate)
    }

    @Test func staleMapBindingsAndReversedManualEdgesRefuseInsteadOfFallingBack() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        var stale = try f.anchor(0)
        stale.mapIdentity = String(repeating: "0", count: 64)
        episode.productionRange = .init(start: .dialogue(stale))
        #expect(throws: EpisodeProductionError.unresolvedBoundary) { try projection(episode) }
        episode.productionRange = .init(start: .absolute(frame: 9 * rate), end: .absolute(frame: rate))
        #expect(throws: EpisodeProductionError.invalidEpisodeRange) { try projection(episode) }
        episode.productionRange = nil
        episode.cleanup?.workingRange?.alignmentRevision = 2
        #expect(throws: EpisodeProductionError.staleSpeakerRange) { try projection(episode) }
    }

    @Test func audioOnlyAndEmptyEpisodesNeverInventDialogueOrPlayableTime() throws {
        let f = try ProgramFixture()
        var episode = f.episode(clips: [f.clip(.absolute(frame: -rate), duration: 3 * rate)])
        episode.alignment = nil
        let value = try projection(episode, coverage: nil)
        #expect(value.episodeFrames == -rate..<2 * rate)
        #expect(value.speakerAlignedFrames == nil)
        #expect(try value.clockFrame(atProgramFrame: 0, clock: .speaker) == nil)
        #expect(try value.programFrame(atClockFrame: 0, clock: .speaker) == nil)
        episode.audioArrangement?.clips = []
        #expect(try projection(episode, coverage: nil).episodeFrames == nil)
        #expect(try projection(episode, coverage: nil).clockFrame(atProgramFrame: 0, clock: .episode) == nil)
        episode.productionRange = .init(start: .absolute(frame: 0), end: .absolute(frame: rate))
        #expect(try projection(episode, coverage: nil).episodeFrames == nil)
    }

    @Test func speechGateRampIsEntirelyInsideSpeakerBounds() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        episode.productionRange = .init(restrictSpeech: true)
        let value = try projection(episode)
        #expect(value.speechGain(atProgramFrame: 0) == 0)
        #expect(value.speechGain(atProgramFrame: 2 * rate - 1) == 0)
        #expect(value.speechGain(atProgramFrame: 2 * rate) == 0)
        #expect(value.speechGain(atProgramFrame: 2 * rate + 120) == 0.5)
        #expect(value.speechGain(atProgramFrame: 2 * rate + 240) == 1)
        #expect(value.speechGain(atProgramFrame: 8 * rate - 241) == 1)
        #expect(value.speechGain(atProgramFrame: 8 * rate - 121) == 0.5)
        #expect(value.speechGain(atProgramFrame: 8 * rate - 1) == 0)
        #expect(value.speechGain(atProgramFrame: 8 * rate) == 0)
    }

    @Test func staleCompositionsAndClockOverflowAreExplicitErrors() throws {
        let f = try ProgramFixture(), episode = speakerEpisode(f)
        let composition = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage).composition()
        var changed = episode
        changed.audioArrangement?.clips = [f.clip(.absolute(frame: 0))]
        #expect(throws: EpisodeProductionError.staleComposition) {
            try EpisodeProductionProjection(episode: changed, composition: composition)
        }
        let value = try projection(episode)
        #expect(throws: EpisodeProductionError.invalidClockPosition) {
            try value.programFrame(atClockFrame: Int64.max, clock: .episode)
        }
        #expect(throws: EpisodeProductionError.invalidClockPosition) {
            try value.clockFrame(atProgramFrame: Int64.min, clock: .timeline)
        }
    }

    @Test func elapsedClocksRoundTripAcrossTheEntireSignedDayEnvelope() throws {
        let f = try ProgramFixture(), limit = AudioArrangement.frameLimit
        var episode = f.episode(clips: [f.clip(.absolute(frame: -limit), duration: rate)])
        episode.productionRange = .init(start: .absolute(frame: -limit), end: .absolute(frame: limit))
        let value = try projection(episode)
        let clockFrame = try value.clockFrame(atProgramFrame: limit - 1, clock: .episode)
        let elapsed = try #require(clockFrame)
        #expect(elapsed == 2 * limit - 1)
        #expect(try value.programFrame(atClockFrame: elapsed, clock: .episode) == limit - 1)
    }

    @Test func removedSpeakerRangeAndFractionalEdgesDoNotInventSamples() throws {
        let f = try ProgramFixture()
        var episode = speakerEpisode(f)
        episode.cleanup?.manualCuts = [f.cut(2 * rate, 8 * rate)]
        #expect(try projection(episode).episodeFrames == nil)
        episode.cleanup?.manualCuts = []
        episode.cleanup?.workingRange = .init(alignmentRevision: 1,
            tracksIn: 2 + 0.25 / Double(rate), tracksOut: 8 + 0.25 / Double(rate))
        let value = try projection(episode)
        #expect(value.speakerAlignedFrames == 2 * rate + 1..<8 * rate + 1)
        episode.cleanup?.workingRange = .init(alignmentRevision: 1, tracksIn: 200)
        #expect(throws: EpisodeProductionError.invalidSpeakerRange) { try projection(episode) }
    }
}
