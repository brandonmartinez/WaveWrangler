import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

enum PipelineRender75Gate {
    static let enabled = ProcessInfo.processInfo.environment["WW_PIPELINE_RENDER75"] == "1"
    static let reason: Comment = "local serialized 75-minute aligned-asset pass (WW_PIPELINE_RENDER75=1, scripts/test.sh)"
}

/// WW-023's full-length engineering envelope. The test stays local-only because a Debug render of this
/// duration cannot fit the CI job's 60-minute budget; scripts/test.sh runs it alone in an optimized build.
@Suite("Pipeline 75-minute aligned-asset render (heavy, local, serialized)", .serialized, .enabled(if: PipelineRender75Gate.enabled, PipelineRender75Gate.reason))
struct PipelineRender75Tests {
    static let seconds = 75.0 * 60
    static let outputRate = 48_000
    static let mebibyte = 1 << 20
    static let targetNames = ["field-a", "field-b", "field-c"]
    static let truth = EpochMapDecision.numeric(ppm: 100, offsetMilliseconds: 1250, note: "synthetic planted truth")

    struct SegmentHeader {
        let header: AlignedAudioSegment.Header
        let sample: (Int64) -> Float?
    }

    static func groups() -> [GroupSpec] {
        let targetRates = [48_000, 44_100, 48_000]
        return [
            GroupSpec(name: "Timeline reference", sources: [
                SourceSpec(name: "reference", channels: 2, seconds: seconds, signal: .scene(seed: TwoRecorder.seed)),
            ]),
            GroupSpec(name: "Three-recorder field group", sources: zip(targetNames, targetRates).map { name, sampleRate in
                SourceSpec(
                    name: name, channels: 2, seconds: seconds,
                    signal: .scene(seed: TwoRecorder.seed, rate: TwoRecorder.rate, offset: TwoRecorder.offset),
                    sampleRate: sampleRate
                )
            }),
        ]
    }

    static func fixture(_ label: String) async throws -> (PipelineFixture, AlignmentAnalysisReport) {
        let configuration = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 180
        )
        let fixture = try await PipelineFixture(groups(), configuration: configuration, label: label)
        let report = try await fixture.analyse(preferredReference: "reference")
        #expect(report.sourceFailures.isEmpty && report.epochFailures.isEmpty)
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: truth])
        return (fixture, report)
    }

    static func renderTargets(_ fixture: PipelineFixture) async throws -> AlignedAssetReport {
        let ids = Set(targetNames.map(fixture.id))
        return try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model,
            episode: fixture.episodeID,
            sources: fixture.sources.filter { ids.contains($0.id) },
            authorizations: fixture.authorizations.filter { ids.contains($0.source) }
        )
    }

    static func segmentHeader(_ data: Data) throws -> SegmentHeader {
        guard data.count >= 8, data.prefix(4) == AlignedAudioSegment.magic else {
            throw AlignedAudioSegment.DecodingError.notAnAlignedSegment
        }
        let jsonLength = data.withUnsafeBytes { bytes in
            let b0 = UInt32(bytes[4])
            let b1 = UInt32(bytes[5]) << 8
            let b2 = UInt32(bytes[6]) << 16
            let b3 = UInt32(bytes[7]) << 24
            return Int(b0 | b1 | b2 | b3)
        }
        guard data.count >= 8 + jsonLength else { throw AlignedAudioSegment.DecodingError.lengthMismatch }
        let header = try JSONDecoder().decode(
            AlignedAudioSegment.Header.self,
            from: data.subdata(in: 8 ..< (8 + jsonLength))
        )
        let bodyStart = 8 + jsonLength
        guard data.count - bodyStart == header.frameCount * MemoryLayout<Float>.size else {
            throw AlignedAudioSegment.DecodingError.lengthMismatch
        }
        return SegmentHeader(header: header) { frame in
            let local = frame - header.firstOutputFrame
            guard local >= 0, local < Int64(header.frameCount) else { return nil }
            let offset = bodyStart + Int(local) * MemoryLayout<Float>.size
            return data.withUnsafeBytes { bytes in
                let b0 = UInt32(bytes[offset])
                let b1 = UInt32(bytes[offset + 1]) << 8
                let b2 = UInt32(bytes[offset + 2]) << 16
                let b3 = UInt32(bytes[offset + 3]) << 24
                let bits = b0 | b1 | b2 | b3
                return Float(bitPattern: bits)
            }
        }
    }

    @Test("A mixed-rate three-recorder group renders all six channels for 75 minutes within the engineering envelope")
    func fullLengthRender() async throws {
        let (fixture, _) = try await Self.fixture("pipeline-render75")
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let targetGroup = try #require(map.group(containing: alignmentOccurrenceID(for: fixture.id(Self.targetNames[0]))))
        let expectedFrames = try #require(try GroupRenderJob.hull(
            map: targetGroup,
            occurrences: Self.targetNames.map { alignmentOccurrenceID(for: fixture.id($0)) },
            outputRate: Self.outputRate
        ))

        let baseline = MemorySampler.now()
        let baselineMax = MemorySampler.maxResident()
        let sampler = MemorySampler()
        let clock = ContinuousClock()
        let started = clock.now
        let rendered = try await Self.renderTargets(fixture)
        let elapsed = clock.now - started
        let peaks = sampler.stop()
        let maxResident = MemorySampler.maxResident()

        #expect(rendered.isComplete)
        #expect(rendered.outputRate == Self.outputRate)
        #expect(rendered.groups.count == 1)
        let group = try #require(rendered.groups.first)
        #expect(group.group == fixture.groups[1])
        #expect(group.outputFrames == expectedFrames)
        #expect(group.failure == nil)
        #expect(group.segmentsRendered == group.segments && group.segmentsReused == 0)
        #expect(group.results.count == group.segments * Self.targetNames.count * 2)
        #expect(group.peakRenderWorkingSetBytes < 64 * Self.mebibyte)

        let sampleFrames = [
            expectedFrames.lowerBound + Int64(5 * Self.outputRate),
            expectedFrames.lowerBound + Int64(expectedFrames.count / 2),
            expectedFrames.upperBound - Int64(5 * Self.outputRate),
        ]
        var frameCounts: [String: Int64] = [:]
        var mapDigests = Set<String>()
        var samples: [Int64: [Float]] = [:]
        var channels = Set<String>()
        var maximumAbsoluteError: Float = 0
        for result in group.results {
            let payload = try #require(fixture.store.payload(for: result.key))
            let segment = try Self.segmentHeader(payload)
            let header = segment.header
            let channel = "\(header.source)/\(header.decodedChannel)"
            channels.insert(channel)
            frameCounts[channel, default: 0] += Int64(header.frameCount)
            mapDigests.insert(header.mapDigest)
            #expect(header.group == fixture.groups[1])
            #expect(header.map == rendered.revision)
            #expect(header.outputRate == Self.outputRate)
            #expect(result.key.channel == header.decodedChannel)
            for frame in sampleFrames {
                if let value = segment.sample(frame) {
                    samples[frame, default: []].append(value / channelGain(header.decodedChannel))
                    let expected = Signal.scene(TwoRecorder.seed, Double(frame) / Double(Self.outputRate))
                    let error = abs(value - channelGain(header.decodedChannel) * expected)
                    maximumAbsoluteError = max(maximumAbsoluteError, error)
                    #expect(error < 0.02)
                }
            }
        }

        #expect(channels.count == Self.targetNames.count * 2)
        #expect(frameCounts.count == channels.count)
        #expect(frameCounts.values.allSatisfy { $0 == Int64(expectedFrames.count) })
        #expect(mapDigests.count == 1, "every same-group channel used the same accepted group transform")
        var maximumNormalizedSpread: Float = 0
        for frame in sampleFrames {
            let aligned = try #require(samples[frame])
            #expect(aligned.count == channels.count)
            let spread = (aligned.max() ?? 0) - (aligned.min() ?? 0)
            maximumNormalizedSpread = max(maximumNormalizedSpread, spread)
            #expect(spread < 0.02, "interchannel skew at output frame \(frame)")
        }
        #expect(fixture.content.total.readsOnMainThread == 0)
        await ConcurrencyTests.expectQuiescent(fixture)

        print("""
        [pipeline-render75] 3 recorders × 2 channels × 75 min; inputs 48/44.1/48 kHz; output 48 kHz
        [pipeline-render75] output \(expectedFrames.count) frames/channel × \(channels.count) channels in \(group.segments) segments
        [pipeline-render75] max absolute truth error \(maximumAbsoluteError); max normalized interchannel spread \(maximumNormalizedSpread); map digests \(mapDigests.count)
        [pipeline-render75] elapsed \(elapsed); peak renderer working set \(group.peakRenderWorkingSetBytes) bytes
        [pipeline-render75] baseline resident \(baseline.resident / Self.mebibyte) MiB, footprint \(baseline.footprint / Self.mebibyte) MiB; ru_maxrss before \(baselineMax / Self.mebibyte) MiB
        [pipeline-render75] sampled peak resident \(peaks.resident / Self.mebibyte) MiB, footprint \(peaks.footprint / Self.mebibyte) MiB; ru_maxrss after \(maxResident / Self.mebibyte) MiB
        """)
        #expect(maxResident <= 1 << 30, "process peak resident \(maxResident / Self.mebibyte) MiB")
        #expect(peaks.resident <= 1 << 30, "sampled peak resident \(peaks.resident / Self.mebibyte) MiB")
        #expect(peaks.footprint <= 1 << 30, "sampled peak footprint \(peaks.footprint / Self.mebibyte) MiB")
    }

    @Test("Cancellation remains responsive after a 75-minute aligned render has begun")
    func cancellationMidRender() async throws {
        let (fixture, _) = try await Self.fixture("pipeline-render75-cancel")
        let watched = ProceduralContentIO.path(fixture.url(Self.targetNames[0]))
        let began = Box(false)
        fixture.content.setOnRead { path, index in
            if path == watched, index >= 4 { began.value = true }
        }
        let render = Task { try await Self.renderTargets(fixture) }
        try await ConcurrencyTests.until { began.value }
        let clock = ContinuousClock()
        let started = clock.now
        await fixture.pipeline.shutdown()
        let cancellationElapsed = clock.now - started
        let report = try await render.value
        #expect(cancellationElapsed < .seconds(5), "shutdown took \(cancellationElapsed)")
        #expect(!report.isComplete)
        #expect(report.groups.allSatisfy { $0.failure == .cancelled })
        let read = fixture.content.record(fixture.url(Self.targetNames[0]))
        #expect(read.furthestFrame < fixture.specs[Self.targetNames[0]]!.frames)
        await ConcurrencyTests.expectQuiescent(fixture)
        print("[pipeline-render75] mid-render cancellation \(cancellationElapsed); stopped at source frame \(read.furthestFrame)")
    }
}

@Suite("Default 75-minute aligned-asset render (local, serialized)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["WW_PIPELINE_DEFAULT75"] == "1",
                "run in a separate optimized process (WW_PIPELINE_DEFAULT75=1)"))
struct PipelineDefaultRender75Tests {
    @Test("Default 10-second segments render every channel and stay inside the measured process envelope")
    func defaultLongForm() async throws {
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2
        )
        let fixture = try await PipelineFixture(
            PipelineRender75Tests.groups(), configuration: config, label: "default-render75"
        )
        let analysis = try await fixture.analyse(preferredReference: "reference")
        try await fixture.acceptAndActivate(analysis, [fixture.epochs[1]: PipelineRender75Tests.truth])
        let baseline = MemorySampler.now()
        let sampler = MemorySampler()
        let report = try await PipelineRender75Tests.renderTargets(fixture)
        let peaks = sampler.stop()
        let rss = MemorySampler.maxResident()
        let group = try #require(report.groups.first)
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let target = try #require(map.groups.first(where: { $0.group == fixture.groups[1] }))
        let expected = try #require(try GroupRenderJob.hull(
            map: target,
            occurrences: PipelineRender75Tests.targetNames.map { alignmentOccurrenceID(for: fixture.id($0)) },
            outputRate: PipelineRender75Tests.outputRate
        ))
        #expect(report.isComplete && report.groups.count == 1)
        #expect(group.outputFrames == expected)
        #expect(group.segments > 256 && group.segments >= 450)
        #expect(group.segmentsRendered == group.segments && group.segmentsReused == 0)
        #expect(group.results.count == group.segments * 6)
        #expect(Set(group.results.map(\.key)).count == group.results.count)
        #expect(group.results.count <= 4096)
        #expect(fixture.content.openReaders == 0)
        let gate = await ResourceGate.process.snapshot
        print("""
        [pipeline-default75] default 10s, six channels, segments \(group.segments), results \(group.results.count)
        [pipeline-default75] baseline RSS \(baseline.resident), footprint \(baseline.footprint); ru_maxrss \(rss), sampled RSS \(peaks.resident), footprint \(peaks.footprint); process gate peak \(gate.peakBytes)
        """)
        #expect(rss <= 1_073_741_824 && peaks.resident <= 1_073_741_824 && peaks.footprint <= 1_073_741_824)
    }
}
