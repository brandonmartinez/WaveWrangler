import Foundation
import Testing
@testable import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived

@Suite("Aligned assets: one common output rate from the WW-050 output-settings policy")
struct OutputSettingsTests {
    /// The short two-recorder episode with the field recorder (and optionally the reference) at 44.1 kHz.
    static func groups(referenceRate: Int = 48_000, targetRate: Int = 44_100) -> [GroupSpec] {
        var groups = TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4) { $0.sampleRate = targetRate }
        groups[0].sources[0].sampleRate = referenceRate
        return groups
    }

    @Test("Mixed 48 / 44.1 kHz sources render at the policy's 48 kHz; the 44.1 kHz source is resampled onto the timeline")
    func mixedRatesRenderAtThePreferredRate() async throws {
        let fixture = try await PipelineFixture(Self.groups(), label: "policy-mixed")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.facts[tgt]?.sampleRate == 44_100)
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])

        let rendered = try await fixture.render()
        #expect(rendered.isComplete)
        let decision = try #require(rendered.outputSettings)
        #expect(decision.policyVersion == OutputSettingsPolicy.version)
        #expect(decision.settings.sampleRate == 48_000)
        #expect(rendered.outputRate == 48_000)
        #expect(decision.reasons.contains(.preferredRateChosen(48_000)))
        #expect(decision.reasons.contains(.sourcesResampled([tgt], outputRate: 48_000)))
        #expect(decision.reasons.contains(.mixedSourceRates([44_100, 48_000])))
        #expect(Set(decision.basis.inputs.map(\.source)) == [fixture.id("ref"), tgt])

        let segments = try alignedSegments(rendered, store: fixture.store)
        #expect(segments.allSatisfy { $0.segment.header.outputRate == 48_000 })
        #expect(segments.allSatisfy { ($0.key.recipe?.name ?? "").contains("rate=48000") && ($0.key.recipe?.name ?? "").contains("policy=\(OutputSettingsPolicy.version)") })
        let end = TwoRecorder.rate * 4 + TwoRecorder.offset
        var checked = 0
        for entry in segments where entry.segment.header.source == tgt {
            let c = entry.segment.header.decodedChannel
            if let check = relativeError(entry.segment.samples, firstFrame: entry.segment.header.firstOutputFrame, rate: 48_000, interval: (TwoRecorder.offset + 0.2) ... (end - 0.2), expected: { channelGain(c) * Signal.scene(TwoRecorder.seed, $0) }) {
                #expect(check.error < 0.02, "44.1 kHz target segment \(entry.segment.header.segmentIndex) ch\(c): \(check.error)")
                checked += check.count
            }
        }
        #expect(checked > 2 * 3 * 48_000, "the resampled target was checked against the timeline truth")
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("All-44.1 kHz sources: the default renders at 48 kHz, `.matchSources` at 44.1 kHz; the rate keys the assets", arguments: [
        (OutputSettingsConfiguration.RateChoice.preferred, 48_000),
        (.matchSources, 44_100),
    ])
    func rateChoiceSetsTheOutputRate(choice: OutputSettingsConfiguration.RateChoice, expected: Int) async throws {
        let configuration = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 20, searchDeviationSeconds: 3, renderSegmentSeconds: 2,
            outputSettings: OutputSettingsConfiguration(rateChoice: choice)
        )
        let fixture = try await PipelineFixture(Self.groups(referenceRate: 44_100), configuration: configuration, label: "policy-choice")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let rendered = try await fixture.render()
        #expect(rendered.isComplete)
        #expect(rendered.outputRate == expected)
        #expect(rendered.outputSettings?.basis.configuration == configuration.outputSettings)
        let segments = try alignedSegments(rendered, store: fixture.store)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.segment.header.outputRate == expected && ($0.key.recipe?.name ?? "").contains("rate=\(expected)") })
        // The reference group is identity on the timeline at whatever rate the policy chose.
        let ref = fixture.id("ref")
        for entry in segments where entry.segment.header.source == ref {
            let c = entry.segment.header.decodedChannel
            if let check = relativeError(entry.segment.samples, firstFrame: entry.segment.header.firstOutputFrame, rate: expected, interval: 0.2 ... 5.8, expected: { channelGain(c) * Signal.scene(TwoRecorder.seed, $0) }) {
                #expect(check.error < 0.02, "reference segment \(entry.segment.header.segmentIndex) ch\(c) at \(expected): \(check.error)")
            }
        }
    }

    @Test("With nothing renderable there is no decision and no output rate, and nothing is opened")
    func nothingRenderableHasNoDecision() async throws {
        let fixture = try await PipelineFixture(Self.groups(), label: "policy-none")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let opens = fixture.content.total.opens
        let rendered = try await fixture.pipeline.renderAlignedAssets(model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: [])
        #expect(rendered.outputSettings == nil && rendered.outputRate == nil)
        #expect(rendered.groups.isEmpty)
        #expect(rendered.notRendered.count == 2)
        #expect(fixture.content.total.opens == opens)
    }
}
