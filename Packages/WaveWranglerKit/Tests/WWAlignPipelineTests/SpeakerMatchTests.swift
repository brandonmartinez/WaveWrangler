import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Speaker-paired alignment in the accepted timeline")
struct SpeakerMatchTests {
    @Test("One-hour and seventy-minute files search a ten-minute offset with bounded memory and no audio decode")
    func longUnequalDurations() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "hour", seconds: 3_600, signal: .silence)]),
            GroupSpec(name: "Two", sources: [.init(name: "seventy", seconds: 4_200, signal: .silence)]),
        ], configuration: AlignmentPipelineConfiguration())
        let report = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let referenceFacts = try #require(report.facts[fixture.id("hour")])
        let targetFacts = try #require(report.facts[fixture.id("seventy")])
        let locator = AlignmentPipeline.speakerLocatorConfiguration(
            durationDifference: -600, base: fixture.configuration
        )
        #expect(locator.targetExcerptSeconds == 60)
        #expect(locator.searchCenterSeconds == -300)
        #expect(locator.searchDeviationSeconds == 300)
        let unit = AnalysisUnit(
            referenceChoice: try #require(report.plan.reference),
            reference: try #require(fixture.sources.first(where: { $0.id == fixture.id("hour") })),
            referenceFacts: referenceFacts, targetGroup: fixture.groups[1],
            targetEpoch: fixture.epochs[1],
            target: try #require(fixture.sources.first(where: { $0.id == fixture.id("seventy") })),
            targetFacts: targetFacts, configuration: locator, chunkFrames: fixture.decoder.configuration.chunkFrames
        )
        #expect(unit.targetRange.lowerBound > 0)
        #expect(unit.referenceRange.count > 0)
        #expect(try unit.estimatedWorkingSetBytes() <= fixture.configuration.analysisMemoryBudgetBytes)
        #expect(fixture.content.total.reads == 0)
    }

    @Test("A longer reference can still match a target that started earlier")
    func reverseDurationHint() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [
                .init(name: "long", seconds: 36, signal: .scene(seed: 77)),
            ]),
            GroupSpec(name: "Two", sources: [
                .init(name: "short", seconds: 28, signal: .scene(seed: 77, offset: -5)),
            ]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("long"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("short"), statedChannel: 0)]
            ),
        ]
        let report = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        let proposal = try #require(report.records[fixture.epochs[1]]?.proposal)
        #expect(abs(proposal.segment.alignedOffset.approximateDouble + 5) < 0.04)
    }

    @Test("An explicit pair selects the already aligned second recorder rather than the first eligible one")
    func explicitPair() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [
                .init(name: "one", seconds: 24, signal: .scene(seed: 27)),
            ]),
            GroupSpec(name: "Two", sources: [
                .init(name: "two", seconds: 24, signal: .scene(seed: 27, offset: 0.2)),
            ]),
            GroupSpec(name: "Three", sources: [
                .init(name: "three", seconds: 24, signal: .scene(seed: 27, offset: 0.4)),
            ]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("one"), statedChannel: 0),
                backups: [
                    ChannelReference(sourceID: fixture.id("two"), statedChannel: 0),
                    ChannelReference(sourceID: fixture.id("three"), statedChannel: 0),
                ]
            ),
        ]
        let first = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        _ = try #require(first.records[fixture.epochs[1]]?.proposal, "\(String(describing: first.records[fixture.epochs[1]]?.abstention)); \(String(describing: first.records[fixture.epochs[1]]?.coarseWindows))")
        _ = try await fixture.acceptAndActivate(first, [fixture.epochs[1]: .acceptProposal()])
        let snapshot = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(snapshot.speakerMatches[fixture.epochs[2]]?.count == 2)
        let report = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[2],
            speaker: speaker, referenceSource: fixture.id("two"), targetSource: fixture.id("three")
        )
        #expect(report.records[fixture.epochs[2]]?.reference.source == fixture.id("two"))
        _ = try #require(report.records[fixture.epochs[2]]?.proposal)
        let moved = try await fixture.pipeline.shiftAcceptedGroup(
            model: fixture.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: 10_000
        )
        fixture.model = moved.model
        try await fixture.pipeline.activate(moved)
        #expect(await fixture.states(report)[fixture.epochs[2]]?.analysis == nil)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: fixture.model, episode: fixture.episodeID, report: report,
                decisions: [fixture.epochs[2]: .acceptProposal()]
            )
        }
    }

    @Test("A shared speaker can chain a drifting third recorder through a previously accepted second recorder")
    func chainedGroups() async throws {
        func source(_ name: String, seconds: Double, seed: UInt64, rate: Double, offset: Double) -> SourceSpec {
            SourceSpec(
                name: name, seconds: seconds, signal: .silence,
                channelSignals: [
                    .scene(seed: UInt64(name.utf8.first ?? 0) + 9_000),
                    .scene(seed: seed, rate: rate, offset: offset),
                ]
            )
        }
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Recorder 1", sources: [
                source("a1", seconds: 28, seed: 11, rate: 1, offset: 0),
            ]),
            GroupSpec(name: "Recorder 2", sources: [
                source("a2", seconds: 36, seed: 11, rate: 1.0002, offset: -4),
                source("b2", seconds: 36, seed: 22, rate: 1.0002, offset: -4),
            ]),
            GroupSpec(name: "Recorder 3", sources: [
                source("b3", seconds: 42, seed: 22, rate: 1.0004, offset: -7),
            ]),
        ])
        let speakerA = SpeakerID()
        let speakerB = SpeakerID()
        func channel(_ name: String) -> ChannelReference {
            ChannelReference(sourceID: fixture.id(name), statedChannel: 1)
        }
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: speakerA, primary: channel("a1"), backups: [channel("a2")]),
            SpeakerAssignment(speakerID: speakerB, primary: channel("b2"), backups: [channel("b3")]),
        ]
        let before = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(before.speakerMatches[fixture.epochs[1]]?.map(\.speaker) == [speakerA])
        #expect(before.speakerMatches[fixture.epochs[2]]?.isEmpty == true)

        let first = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speakerA
        )
        let firstProposal = try #require(first.records[fixture.epochs[1]]?.proposal)
        #expect(first.records[fixture.epochs[1]]?.recipe.contains("channels=1,1") == true)
        #expect(abs(firstProposal.segment.alignedOffset.approximateDouble + 4) < 0.04)
        #expect(abs(firstProposal.ppm - 200) < 150)
        let savedFirst = try await fixture.acceptAndActivate(first, [fixture.epochs[1]: .acceptProposal()])
        let firstGroup = try #require(savedFirst.map.groups.first(where: { $0.group == fixture.groups[1] }))
        #expect(firstGroup.placements.contains { $0.occurrence.source == fixture.id("b2") })

        let after = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        let secondOption = try #require(after.speakerMatches[fixture.epochs[2]]?.first)
        #expect(secondOption.speaker == speakerB)
        #expect(secondOption.reference.source == fixture.id("b2"))
        let second = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[2], speaker: speakerB
        )
        let proposal = try #require(second.records[fixture.epochs[2]]?.proposal)
        #expect(second.records[fixture.epochs[2]]?.reference.source == fixture.id("b2"))
        #expect(abs(proposal.segment.alignedOffset.approximateDouble + 7) < 0.06)
        #expect(abs(proposal.ppm - 400) < 150)
        let savedSecond = try await fixture.acceptAndActivate(second, [fixture.epochs[2]: .acceptProposal()])
        #expect(savedSecond.map.reference == savedFirst.map.reference)
        #expect(savedSecond.map.groups.first(where: { $0.group == fixture.groups[1] }) == firstGroup)
        #expect(savedSecond.map.groups.first(where: { $0.group == fixture.groups[2] })?.epochs.first?.mapping != .unsupported(.notAttempted))
        let version = try #require(savedSecond.model.episode(fixture.episodeID)?.alignment?.map(
            revision: savedSecond.revision.revision
        ))
        #expect(MapDependencies.acceptedProposals(version)[fixture.epochs[1].description] != nil)
        #expect(MapDependencies.acceptedProposals(version)[fixture.epochs[2].description] != nil)
        for name in ["a1", "a2", "b2", "b3"] {
            #expect(try Data(contentsOf: fixture.url(name)) == Data(repeating: 0x5A, count: 4096))
        }
        #expect(fixture.content.openReaders == 0)
    }

    @Test("Unknown channels and unsupported reference epochs never become a speaker match")
    func unknownAndUnsupported() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", seconds: 22, signal: .scene(seed: 1))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 22, signal: .scene(seed: 1))]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("one"), statedChannel: nil),
                backups: [ChannelReference(sourceID: fixture.id("two"), statedChannel: 0)]
            ),
        ]
        let snapshot = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(snapshot.speakerMatches[fixture.epochs[1]]?.isEmpty == true)
        #expect(fixture.content.total.reads == 0)
        fixture.model = try fixture.model.settingStatedChannel(
            0, forSource: fixture.id("one"), in: fixture.episodeID
        )
        let corrected = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(corrected.speakerMatches[fixture.epochs[1]]?.map(\.speaker) == [speaker])
        #expect(fixture.content.total.reads == 0)
        fixture.model = try fixture.model.settingStatedChannel(
            nil, forSource: fixture.id("one"), in: fixture.episodeID
        )
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.analyzeSpeaker(
                model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
                authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
            )
        }
    }

    @Test("A speaker proposal is bound to the accepted reference revision")
    func changedReference() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", seconds: 24, signal: .scene(seed: 42))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 24, signal: .scene(seed: 42, offset: 0.25))]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("one"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("two"), statedChannel: 0)]
            ),
        ]
        let report = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        _ = try #require(report.records[fixture.epochs[1]]?.proposal, "\(String(describing: report.records[fixture.epochs[1]]?.abstention)); \(String(describing: report.records[fixture.epochs[1]]?.coarseWindows))")
        let assignment = fixture.model.episodes[0].speakerAssignments
        fixture.model.episodes[0].speakerAssignments = []
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: fixture.model, episode: fixture.episodeID, report: report,
                decisions: [fixture.epochs[1]: .acceptProposal()]
            )
        }
        fixture.model.episodes[0].speakerAssignments = assignment
        _ = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: .acceptProposal()])
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: fixture.model, episode: fixture.episodeID, report: report,
                decisions: [fixture.epochs[1]: .acceptProposal()]
            )
        }
        #expect(await fixture.states(report)[fixture.epochs[1]]?.analysis == nil)
    }

    @Test("A silent assigned channel abstains and cannot be accepted")
    func silenceRefuses() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [
                .init(name: "one", seconds: 24, signal: .silence,
                      channelSignals: [.scene(seed: 3), .silence]),
            ]),
            GroupSpec(name: "Two", sources: [
                .init(name: "two", seconds: 24, signal: .silence,
                      channelSignals: [.scene(seed: 3), .silence]),
            ]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("one"), statedChannel: 1),
                backups: [ChannelReference(sourceID: fixture.id("two"), statedChannel: 1)]
            ),
        ]
        let report = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        #expect(report.records[fixture.epochs[1]]?.proposal == nil)
        #expect(report.records[fixture.epochs[1]]?.abstention != nil)
        await #expect(throws: AlignmentAcceptanceError.noCurrentProposal(fixture.epochs[1])) {
            try await fixture.pipeline.accept(
                model: fixture.model, episode: fixture.episodeID, report: report,
                decisions: [fixture.epochs[1]: .acceptProposal()]
            )
        }
        #expect(fixture.model.episodes[0].alignment == nil)
    }
}
