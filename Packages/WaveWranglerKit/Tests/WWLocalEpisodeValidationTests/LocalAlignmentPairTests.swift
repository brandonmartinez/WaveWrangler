import Foundation
import Testing
import WWAlignEstimate
@testable import WWAutoAlign
@testable import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap

private enum PairEnvironment {
    static let reference = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_REFERENCE"]
    static let target = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_TARGET"]
    static let scratch = ProcessInfo.processInfo.environment["WW_LOCAL_SCRATCH_DIR"]
    static let start = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_START"]
    static let end = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_END"]
    static let offset = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_OFFSET"]
    static let adaptive = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_ADAPTIVE"] == "1"
    static let application = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_APPLICATION"] == "1"
    static let estimated = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_ESTIMATED"] == "1"
    static let replay = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_REPLAY"]
    static let temporal = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_TEMPORAL"] == "1"
    static let energy = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_ENERGY"] == "1"
    static let localized = ProcessInfo.processInfo.environment["WW_LOCAL_ALIGNMENT_LOCALIZED"] == "1"
}

private struct SubwindowEnergy: Sendable, Codable {
    let fullCenter: Double
    let center: Double
    let seconds: Double
    let score: Double
    let competingScore: Double
    let measuredOffset: Double
    let parentOffset: Double
    let targetRMS: Double
    let referenceRMS: Double
    let targetPeak: Double
    let referencePeak: Double
}

private struct ActivityBin: Sendable, Codable {
    let center: Double
    let seconds: Double
    let rms: Double
    let fullySupported: Bool
}

/// Explicitly authorized files only. No enumeration, playback, transcription or real-document/original writes.
@Suite("Local alignment pair (explicit opt-in)", .serialized,
       .enabled(if: PairEnvironment.reference != nil && PairEnvironment.target != nil))
struct LocalAlignmentPairTests {
    @Test(.timeLimit(.minutes(30)))
    func diagnoseApprovedPair() async throws {
        guard !PairEnvironment.adaptive
            || (PairEnvironment.start == nil && PairEnvironment.end == nil && PairEnvironment.offset == nil) else {
            throw HarnessError("adaptive and interval-only diagnostics must be run separately")
        }
        guard !PairEnvironment.localized || (!PairEnvironment.adaptive && PairEnvironment.start != nil
            && !PairEnvironment.energy && !PairEnvironment.application) else {
            throw HarnessError("localized waveform diagnostics require interval-only mode without application or energy")
        }
        let urls = [
            URL(fileURLWithPath: try #require(PairEnvironment.reference)),
            URL(fileURLWithPath: try #require(PairEnvironment.target)),
        ]
        let scratchURL = try ConsentGuards.checkScratch(
            URL(fileURLWithPath: try #require(PairEnvironment.scratch)), episode: urls[0].deletingLastPathComponent()
        )
        for url in urls {
            try ConsentGuards.checkScratch(scratchURL, episode: url.deletingLastPathComponent())
        }

        let io = SystemSourceIO()
        let fingerprints = try urls.map { url in
            guard case let .success(metadata) = io.metadata(at: url),
                  metadata.isRegularFile.value == true, metadata.isSymbolicLink.value == false,
                  metadata.isDataless.value == false, metadata.volumeIsLocal.value == true else {
                throw HarnessError("an authorized source is unavailable or not materialized locally")
            }
            return metadata.fingerprint
        }
        let digests = try urls.enumerated().map {
            try ConsentGuards.sha256($0.element, label: "S\($0.offset + 1)")
        }
        defer {
            for index in urls.indices {
                do {
                    guard case let .success(metadata) = io.metadata(at: urls[index]) else {
                        throw HarnessError("source metadata unavailable after diagnosis")
                    }
                    #expect(metadata.fingerprint == fingerprints[index], "S\(index + 1) metadata must remain unchanged")
                    #expect(try ConsentGuards.sha256(urls[index], label: "S\(index + 1)") == digests[index],
                            "S\(index + 1) bytes must remain unchanged")
                } catch {
                    Issue.record("S\(index + 1) immutability could not be verified: \(type(of: error))")
                }
            }
        }
        let cache = scratchURL.appendingPathComponent("derived-cache", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: cache) }
            catch { Issue.record("diagnostic cache cleanup failed: \(type(of: error))") }
        }
        let store = try DerivedAssetStore(root: cache, sourceLocations: urls)
        let coordinator = DerivedJobCoordinator(store: store)
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        let pipeline = AlignmentPipeline(
            coordinator: coordinator, decoder: decoder,
            configuration: AlignmentPipelineConfiguration(concurrency: 1)
        )
        let epochs = [RecordingEpoch(label: "S1"), RecordingEpoch(label: "S2")]
        let groups = epochs.enumerated().map {
            RecorderGroup(name: "S\($0.offset + 1)", epochs: [$0.element])
        }
        let records = urls.indices.map { index in
            SourceRecord(displayNameHint: "S\(index + 1)", placement: SourcePlacement(
                recorderGroupID: groups[index].id, epochID: epochs[index].id
            ))
        }
        let sources = urls.indices.map { index in
            AlignmentSource(id: records[index].id, url: urls[index], availability: .on,
                            recordedFingerprint: fingerprints[index])
        }
        for index in urls.indices {
            await coordinator.updateSource(SourceRevision.metadata(records[index].id, fingerprint: fingerprints[index]))
        }
        let speaker = Speaker(name: "Shared speaker")
        let authorizations = sources.map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        do {
            for reference in PairEnvironment.start == nil && !PairEnvironment.adaptive ? Array(urls.indices) : [0] {
                let target = 1 - reference
                let episode = Episode(
                    title: "Authorized diagnostic", recorderGroups: [groups[reference], groups[target]],
                    sources: [records[reference], records[target]], speakerAssignments: [
                        SpeakerAssignment(speakerID: speaker.id,
                            primary: ChannelReference(sourceID: records[reference].id, statedChannel: 0),
                            backups: [ChannelReference(sourceID: records[target].id, statedChannel: 0)])
                    ]
                )
                let model = ShowDocumentModel(show: Show(title: "Authorized diagnostic"),
                                              speakers: [speaker], episodes: [episode])
                if PairEnvironment.adaptive {
                    let record = try await pipeline.analyzeAdaptiveSpeaker(
                        model: model, episode: episode.id, sources: sources, authorizations: authorizations,
                        targetEpoch: epochs[target].id, speaker: speaker.id,
                        referenceSource: records[reference].id, targetSource: records[target].id
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(record).write(to: scratchURL.appendingPathComponent("adaptive.json"), options: .withoutOverwriting)
                    print("WWPAIR-ADAPTIVE | runs=\(record.timing.regions.count); supportedSeconds=\(record.timing.supportedSeconds); "
                        + "quietTransitions=\(record.timing.quietTransitions?.count ?? 0); quietSeconds=\(record.timing.quietSeconds); "
                        + "guidedRuns=\(record.timing.anchoredRecovery?.regions.count ?? 0); guidedSeconds=\(record.timing.anchoredRecovery?.supportedSeconds ?? 0); "
                        + "estimatedSeconds=\(record.timing.estimatedIntervals.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }); "
                        + "usable=\(record.timing.usableWindows)/\(record.timing.attemptedWindows); "
                        + "refusal=\(record.refusal ?? "none"); no timing accepted")
                    let quiet = record.windows.filter { ["sharedSilence", "silent"].contains($0.status) }.count
                    let sequenceCenters = record.windows.filter {
                        $0.status == "eligible"
                            && [AdaptiveAlignment.sequenceMethod, AdaptiveAlignment.quietSequenceMethod].contains($0.method)
                    }.compactMap { $0.corroborations?.dropFirst().first?.targetCenter }
                    let quietSequence = record.windows.filter {
                        $0.status == "eligible" && $0.method == AdaptiveAlignment.quietSequenceMethod
                    }.count
                    let sequenceRuns = record.timing.regions.filter { region in
                        sequenceCenters.contains { $0 >= region.sourceStart && $0 <= region.sourceEnd }
                    }.count
                    print("WWPAIR-COVERAGE | quietStatusWindows=\(quiet); nonQuietStatusWindows=\(record.windows.count - quiet); "
                        + "sequenceWindows=\(sequenceCenters.count); sequenceRuns=\(sequenceRuns); "
                        + "quietSequenceWindows=\(quietSequence); status proxy, not speech recall")
                    #expect(model.episodes[0].alignment == nil)
                    if PairEnvironment.energy {
                        let facts = try await pipeline.prepareManual(
                            model: model, episode: episode.id, sources: sources, authorizations: authorizations
                        ).facts
                        try await diagnoseActivity(pipeline: pipeline,
                            source: try #require(sources.first { $0.id == record.target.source }),
                            facts: try #require(facts[record.target.source]), timing: record.timing, output: scratchURL)
                    }
                    if PairEnvironment.application, !record.timing.regions.isEmpty {
                        let accepted = try await pipeline.acceptAdaptive(model: model, episode: episode.id,
                            record: record, sources: sources, authorizations: authorizations,
                            includeEstimated: PairEnvironment.estimated)
                        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
                        let restored = try coder.decode(coder.encode(accepted.model, revision: 1)).payload
                        #expect(restored == accepted.model)
                        try await pipeline.activate(accepted)
                        let correction = try #require(restored.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
                        let region = try #require(correction.segments.first)
                        let witness = try await decoder.captureRawIdentity(urls[target], matching: fingerprints[target])
                        let audio = try await pipeline.adaptiveAudioWindow(model: restored, episode: episode.id,
                            source: records[target].id, sourceURL: urls[target], matching: witness,
                            startSeconds: region.alignedStart + 0.05,
                            durationSeconds: min(0.5, region.alignedEnd - region.alignedStart - 0.1))
                        #expect(audio.count == correction.channelCount)
                        #expect(audio.allSatisfy { $0.allSatisfy(\.isFinite) })
                        #expect(audio[0].contains { abs($0) > 0.00001 })
                        try await verifyAppliedDelay(pipeline: pipeline, model: restored, episode: episode.id,
                            sources: sources, authorizations: authorizations, record: record,
                            correction: correction, targetURL: urls[target], witness: witness)
                        print("WWPAIR-ADAPTIVE-APPLICATION | ephemeral schema round-trip and native multichannel audio passed; no real show changed")
                    }
                    continue
                }
                if PairEnvironment.start != nil {
                    let report = try await pipeline.prepareManual(
                        model: model, episode: episode.id, sources: sources, authorizations: authorizations
                    )
                    try await diagnoseInterval(pipeline: pipeline, sources: sources, facts: report.facts, output: scratchURL)
                    #expect(model.episodes[0].alignment == nil)
                    continue
                }
                let report = try await pipeline.analyzeSpeaker(
                    model: model, episode: episode.id, sources: sources, authorizations: authorizations,
                    targetEpoch: epochs[target].id, speaker: speaker.id, referenceSource: records[reference].id,
                    targetSource: records[target].id
                )
                #expect(report.sourceFailures.isEmpty && report.epochFailures.isEmpty)
                let record = try #require(report.records[epochs[target].id], "diagnostic record missing")
                let output = scratchURL.appendingPathComponent("reference-S\(reference + 1).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: output, options: .withoutOverwriting)
                print("WWPAIR | reference=S\(reference + 1); target=S\(target + 1); estimator=\(record.estimator); "
                    + "usable=\(record.coverage.eligibleCount)/\(record.coverage.windowCount); "
                    + "coarsePPM=\(record.refinementRatePPM ?? .nan); "
                    + "result=\(record.abstention?.reason ?? "proposal-not-accepted")")
                for window in record.windows {
                    print("WWPAIR | region=\(window.index); sourceSeconds=\(window.groupClockCenter); "
                        + "offsetSeconds=\(window.offsetSeconds ?? .nan); status=\(window.status); "
                        + "ncc=\(window.peakScore); phatOffset=\(window.phatOffsetSeconds ?? .nan)")
                }
                #expect(model.episodes[0].alignment == nil, "diagnosis must never accept timing")
            }
        } catch {
            await pipeline.shutdown()
            throw HarnessError("pair diagnosis failed: \(type(of: error))")
        }
        await pipeline.shutdown()
        print("WWPAIR | complete; original metadata and SHA-256 verified on exit; no timing accepted")
    }

    private func verifyAppliedDelay(
        pipeline: AlignmentPipeline, model: ShowDocumentModel, episode: EpisodeID,
        sources: [AlignmentSource], authorizations: [ContentWorkAuthorization], record: AdaptiveAnalysisRecord,
        correction: SourceTimingCorrection, targetURL: URL, witness: RawSourceIdentity
    ) async throws {
        let probes = record.windows.compactMap { window -> (WindowRecord, SourceTimingSegment)? in
            let offset = [AdaptiveAlignment.sequenceMethod, AdaptiveAlignment.quietSequenceMethod].contains(window.method)
                ? window.corroborations?.dropFirst().first?.offsetSeconds : window.offsetSeconds
            guard window.status == "eligible", window.peakScore >= 0.6, let offset,
                  let segment = correction.segments.first(where: {
                      window.groupClockCenter >= $0.sourceStart + 0.26
                          && window.groupClockCenter <= $0.sourceEnd - 0.26
                          && abs(($0.alignedStart + (window.groupClockCenter - $0.sourceStart) * $0.rateRatio)
                              - window.groupClockCenter - offset) <= 0.001
                  }) else { return nil }
            return (window, segment)
        }
        var selected = [("strong", try #require(probes.max { $0.0.peakScore < $1.0.peakScore }))]
        let sequence = probes.filter { $0.0.method == AdaptiveAlignment.sequenceMethod }
        if let probe = sequence.max(by: {
            ($0.0.corroborations?.dropFirst().first?.score ?? 0)
                < ($1.0.corroborations?.dropFirst().first?.score ?? 0)
        }) {
            selected.append(("sequence", probe))
        } else {
            print("WWPAIR-ADAPTIVE-AUDIO | sequence probe unavailable in the bounded interior selection; not verified")
        }
        let quietSequence = probes.filter { $0.0.method == AdaptiveAlignment.quietSequenceMethod }
        if let probe = quietSequence.max(by: {
            ($0.0.corroborations?.dropFirst().first?.score ?? 0)
                < ($1.0.corroborations?.dropFirst().first?.score ?? 0)
        }) {
            selected.append(("quiet-sequence", probe))
        } else {
            print("WWPAIR-ADAPTIVE-AUDIO | quiet-sequence probe unavailable in the bounded interior selection; not verified")
        }
        let spectral = probes.filter { $0.0.method == AdaptiveAlignment.spectralMethod }.sorted {
            ($0.0.spectralWitness?.corroborations.dropFirst().first?.score ?? 0)
                < ($1.0.spectralWitness?.corroborations.dropFirst().first?.score ?? 0)
        }
        if !spectral.isEmpty {
            for (index, probe) in spectral.enumerated() {
                selected.append(("spectral-\(index)", probe))
            }
        } else {
            print("WWPAIR-ADAPTIVE-AUDIO | spectral probe unavailable in the bounded interior selection; not verified")
        }
        let shorter = probes.filter { $0.0.method == AdaptiveAlignment.shortMethod }
        for (index, probe) in shorter.enumerated() {
            selected.append(("short-\(index)", probe))
        }
        print("WWPAIR-ADAPTIVE-AUDIO | eligible bounded-interior short probes=\(shorter.count)")
        try #require(record.referenceToAlignedRate == 1 && record.referenceToAlignedOffset == 0)
        let facts = try await pipeline.prepareManual(model: model, episode: episode,
            sources: sources, authorizations: authorizations).facts
        let reference = try #require(facts[record.reference.source])
        let source = try #require(sources.first { $0.id == record.reference.source })
        let factor = try AnalysisDecimator.factor(sourceRate: reference.sampleRate, minimumRate: 8000)
        var nativeProbes = selected.map { (label: $0.0, center: $0.1.0.groupClockCenter, width: 0.5, segment: $0.1.1) }
        let guided = correction.segments.filter { $0.kind == .anchorGuided }
        for (index, region) in guided.enumerated() {
            var centers = Array(stride(from: region.sourceStart + 0.135, through: region.sourceEnd - 0.135, by: 0.125))
            centers.append((region.sourceStart + region.sourceEnd) / 2)
            for (sample, center) in centers.enumerated() {
                nativeProbes.append(("guided-\(index)-\(sample)", center, 0.25, region))
            }
        }
        print("WWPAIR-ADAPTIVE-AUDIO | guided regions=\(guided.count); guided output probes=\(nativeProbes.count - selected.count)")
        var failedProbes: [String] = []
        for (label, sourceCenter, width, segment) in nativeProbes {
            let center = segment.alignedStart + (sourceCenter - segment.sourceStart) * segment.rateRatio
            let start = floor((center - width / 2) * 48000) / 48000
            let actual = try await pipeline.adaptiveAudioWindow(model: model, episode: episode, source: correction.source,
                sourceURL: targetURL, matching: witness, startSeconds: start, durationSeconds: width)
            let lo = Int64(floor((start - 0.05) * Double(reference.sampleRate)))
            let hi = Int64(ceil((start + width + 0.05) * Double(reference.sampleRate)))
            try #require(lo >= 0 && hi <= reference.frameCount)
            let buffers = try await pipeline.gate.withAdmission(bytes: 64 << 20) {
                try await AutomaticAnalysis.buffers(source, facts: reference, ranges: [lo..<hi],
                    channel: 0, minimumRate: 8000, decoder: pipeline.decoder)
            }
            let target = try Statistics.centered(Signal.speechBand(Signal(
                SampleBuffer(samples: actual[0], sampleRate: 48000)).samples))
            let expected = try Signal.speechBand(Signal(SampleBuffer(samples: buffers[0],
                sampleRate: reference.sampleRate / factor)).samples)
            try #require(expected.count >= target.count && !target.isEmpty)
            let energy = target.reduce(0) { $0 + $1 * $1 }
            try #require(energy > 1e-12)
            var bestScore = 0.0, bestLag = 0
            for lag in 0...expected.count - target.count {
                let samples = expected[lag..<lag + target.count]
                let sum = samples.reduce(0, +)
                let variance = max(1e-12, samples.reduce(0) { $0 + $1 * $1 } - sum * sum / Double(target.count))
                let dot = zip(target, samples).reduce(0) { $0 + $1.0 * $1.1 }
                let score = abs(dot) / sqrt(energy * variance)
                if score > bestScore { bestScore = score; bestLag = lag }
            }
            let error = Double(lo) / Double(reference.sampleRate) + Double(bestLag) / Signal.rate - start
            print("WWPAIR-ADAPTIVE-AUDIO | probe=\(label); independent direct NCC=\(bestScore); "
                + "native residualMs=\(error * 1000); toleranceMs=5")
            if bestScore < 0.55 || abs(error) > 0.005 { failedProbes.append(label) }
        }
        try #require(failedProbes.isEmpty,
            "native corrected speech must match the fixed reference at unchanged NCC/residual gates; failed probes: \(failedProbes)")
    }

    private func diagnoseActivity(
        pipeline: AlignmentPipeline, source: AlignmentSource, facts: SourceFacts,
        timing: AdaptiveTimingResult, output: URL
    ) async throws {
        let start = timing.measuredStart, end = timing.measuredEnd
        try #require(start.isFinite && end.isFinite && start >= 0 && end > start
            && end <= Double(facts.frameCount) / Double(facts.sampleRate))
        let count = Int(ceil((end - start) * 10))
        let factor = try AnalysisDecimator.factor(sourceRate: facts.sampleRate, minimumRate: 8000)
        let bytes = (16 << 20) + 6 * pipeline.decoder.configuration.chunkFrames
            * facts.channelCount * MemoryLayout<Float>.size
        var bins: [ActivityBin] = []
        for first in stride(from: 0, to: count, by: 300) {
            let last = min(first + 300, count)
            let lo = max(0, Int64(floor((start + Double(first) / 10 - 0.1) * Double(facts.sampleRate))))
            let hi = min(facts.frameCount, Int64(ceil((min(end, start + Double(last) / 10) + 0.1) * Double(facts.sampleRate))))
            bins += try await pipeline.gate.withAdmission(bytes: bytes) {
                let buffers = try await AutomaticAnalysis.buffers(
                    source, facts: facts, ranges: [lo..<hi], channel: 0, minimumRate: 8000, decoder: pipeline.decoder)
                let samples = try Signal.speechBand(Signal(
                    SampleBuffer(samples: buffers[0], sampleRate: facts.sampleRate / factor)).samples)
                return try (first..<last).map { index in
                    let lower = start + Double(index) / 10, upper = min(end, start + Double(index + 1) / 10)
                    let a = Int(ceil((lower - Double(lo) / Double(facts.sampleRate)) * Signal.rate))
                    let b = Int(floor((upper - Double(lo) / Double(facts.sampleRate)) * Signal.rate))
                    guard a >= 0, b > a, b <= samples.count else {
                        throw HarnessError("activity bin outside witnessed source")
                    }
                    return ActivityBin(center: (lower + upper) / 2, seconds: upper - lower,
                        rms: Statistics.rms(Statistics.centered(Array(samples[a..<b]))),
                        fullySupported: timing.regions.contains { $0.sourceStart <= lower && $0.sourceEnd >= upper })
                }
            }
        }
        let active = bins.filter { $0.rms >= 1e-4 }
        let seconds = active.reduce(0) { $0 + $1.seconds }
        let supported = active.filter(\.fullySupported).reduce(0) { $0 + $1.seconds }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bins).write(to: output.appendingPathComponent("activity.json"), options: .withoutOverwriting)
        print("WWPAIR-ACTIVITY | thresholdRMS=0.0001; binSeconds=0.1; activeSeconds=\(seconds); "
            + "supportedActiveSeconds=\(supported); amplitude proxy, not speech recall; no timing accepted")
    }

    private func diagnoseInterval(
        pipeline: AlignmentPipeline, sources: [AlignmentSource], facts: [SourceID: SourceFacts], output: URL
    ) async throws {
        let start = try #require(PairEnvironment.start.flatMap(Double.init))
        let end = try #require(PairEnvironment.end.flatMap(Double.init))
        let offset = try #require(PairEnvironment.offset.flatMap(Double.init))
        guard start.isFinite, end.isFinite, offset.isFinite, start >= 0, end - start >= 4, end - start <= 120 else {
            throw HarnessError("diagnostic interval must be finite and between four and 120 seconds")
        }
        let reference = try #require(facts[sources[0].id])
        let target = try #require(facts[sources[1].id])
        let times = Array(stride(from: start, through: end - 4, by: 3))
        func frames(_ starts: [Double], seconds: Double, facts: SourceFacts) throws -> [Range<Int64>] {
            try starts.map {
                let lo = $0 * Double(facts.sampleRate), hi = ($0 + seconds) * Double(facts.sampleRate)
                guard lo >= 0, hi <= Double(facts.frameCount) else { throw HarnessError("diagnostic window outside source") }
                return Int64(ceil(lo))..<Int64(floor(hi))
            }
        }
        let targetRanges = try frames(times, seconds: 4, facts: target)
        let referenceRanges = try frames(times.map { $0 + offset - 0.37 }, seconds: 4.74, facts: reference)
        let (observations, energies) = try await pipeline.gate.withAdmission(bytes: 64 << 20) {
            let targets = try await AutomaticAnalysis.buffers(
                sources[1], facts: target, ranges: targetRanges, channel: 0, minimumRate: 8000, decoder: pipeline.decoder
            )
            let references = try await AutomaticAnalysis.buffers(
                sources[0], facts: reference, ranges: referenceRanges, channel: 0, minimumRate: 8000, decoder: pipeline.decoder
            )
            func track(_ samples: [Float], range: Range<Int64>, facts: SourceFacts) throws -> EstimatorTrack {
                let factor = try AnalysisDecimator.factor(sourceRate: facts.sampleRate, minimumRate: 8000)
                return try EstimatorTrack(
                    group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: alignmentOccurrenceID(for: facts.source),
                    groupClockStart: ExactRational(range.lowerBound, Int64(facts.sampleRate)),
                    buffer: SampleBuffer(samples: samples, sampleRate: facts.sampleRate / factor)
                )
            }
            var windows: [WindowRecord] = []
            var energies: [SubwindowEnergy] = []
            for index in times.indices {
                let r = try track(references[index], range: referenceRanges[index], facts: reference)
                let t = try track(targets[index], range: targetRanges[index], facts: target)
                let measured = try PairEnvironment.localized
                    ? LocalizedTimingProbe.measure(reference: r, target: t,
                        station: index % AutomaticAlignment.stationCount, predictedOffset: offset)
                        + LocalizedTimingProbe.measure(reference: r, target: t,
                            station: index % AutomaticAlignment.stationCount, predictedOffset: offset,
                            upperSpeech: true)
                        + AdaptiveAlignment.measure(reference: r, target: t,
                            station: index % AutomaticAlignment.stationCount, predictedOffset: offset, deviation: 0.35)
                        + LocalizedTimingProbe.measureUpperSpeech(reference: r, target: t,
                            station: index % AutomaticAlignment.stationCount, predictedOffset: offset)
                    : PairEnvironment.temporal
                    ? AdaptiveAlignment.measure(reference: r, target: t,
                        station: index % AutomaticAlignment.stationCount, predictedOffset: offset, deviation: 0.35)
                    : AutomaticAlignment.measure(reference: r, target: t,
                        station: index % AutomaticAlignment.stationCount, predictedOffset: offset, deviation: 0.35)
                windows += measured.map {
                    WindowRecord(index: index, groupClockCenter: $0.targetCenter, status: $0.status,
                                 peakScore: $0.nccScore, secondPeakScore: $0.nccSecond, periodicityScore: 0,
                                 offsetSeconds: $0.offsetSeconds, method: $0.method, phatOffsetSeconds: $0.phatOffsetSeconds,
                                 phatPeakRatio: $0.phatPeakRatio, polarity: $0.polarity, corroborations: $0.corroborations,
                                 spectralWitness: $0.spectralWitness)
                }
                if PairEnvironment.energy {
                    let referenceSamples = try Signal.speechBand(Signal(r.buffer).samples)
                    let targetSamples = try Signal.speechBand(Signal(t.buffer).samples)
                    func samples(_ values: [Double], center: Double, start: Double, seconds: Double) throws -> [Double] {
                        let first = Int(((center - seconds / 2 - start) * Signal.rate).rounded())
                        let count = Int((seconds * Signal.rate).rounded())
                        guard first >= 0, count > 0, first + count <= values.count else {
                            throw HarnessError("energy diagnostic outside witnessed interval")
                        }
                        return Statistics.centered(Array(values[first..<first + count]))
                    }
                    for point in measured {
                        guard let parentOffset = point.offsetSeconds else { continue }
                        for check in point.corroborations ?? [] {
                            let seconds = check.windowSeconds ?? 0.5
                            let a = try samples(targetSamples, center: check.targetCenter,
                                start: t.groupClockStart.approximateDouble, seconds: seconds)
                            let b = try samples(referenceSamples, center: check.targetCenter + parentOffset,
                                start: r.groupClockStart.approximateDouble, seconds: seconds)
                            energies.append(SubwindowEnergy(fullCenter: point.targetCenter, center: check.targetCenter,
                                seconds: seconds, score: check.score, competingScore: check.competingScore,
                                measuredOffset: check.offsetSeconds, parentOffset: parentOffset,
                                targetRMS: Statistics.rms(a), referenceRMS: Statistics.rms(b),
                                targetPeak: try #require(a.map(abs).max()),
                                referencePeak: try #require(b.map(abs).max())))
                        }
                    }
                }
            }
            return (windows, energies)
        }
        for window in observations {
            print("WWPAIR-DENSE | sourceSeconds=\(window.groupClockCenter); offsetSeconds=\(window.offsetSeconds ?? .nan); "
                + "status=\(window.status); ncc=\(window.peakScore); phatOffset=\(window.phatOffsetSeconds ?? .nan)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observations).write(to: output.appendingPathComponent("dense.json"), options: .withoutOverwriting)
        if PairEnvironment.localized {
            for (method, points) in Dictionary(grouping: observations, by: { $0.method ?? "unlabeled" })
                .sorted(by: { $0.key < $1.key }) {
                print("WWPAIR-LOCALIZED | method=\(method); eligible=\(points.filter { $0.status == "eligible" }.count)/\(points.count); "
                    + "fresh waveform searches; diagnostic only, no timing regions or acceptance")
            }
        }
        if PairEnvironment.energy {
            try encoder.encode(energies).write(to: output.appendingPathComponent("energy.json"), options: .withoutOverwriting)
            print("WWPAIR-ENERGY | measuredSubwindows=\(energies.count); centered speech-band RMS/peak, not speech labels; no timing accepted")
        }
    }
}

/// Re-evaluates anonymous numeric observations, never reads media or promotes old failed windows.
@Suite("Local adaptive numeric replay (explicit opt-in)", .serialized,
       .enabled(if: PairEnvironment.replay != nil))
struct LocalAdaptiveEvidenceReplayTests {
    @Test func regroupAnonymousObservationsWithoutDecodingSources() throws {
        let url = URL(fileURLWithPath: try #require(PairEnvironment.replay))
        let record = try JSONDecoder().decode(AdaptiveAnalysisRecord.self, from: Data(contentsOf: url))
        guard record.version == AdaptiveAlignment.version, record.estimator == AdaptiveAlignment.identifier else {
            throw HarnessError("numeric replay requires evidence measured by the current adaptive algorithm")
        }
        let observations = record.windows.enumerated().map { index, window in
            DelayEvidence(station: index % AutomaticAlignment.stationCount, attempt: 0,
                targetCenter: window.groupClockCenter, status: window.status,
                offsetSeconds: window.offsetSeconds, nccScore: window.peakScore, nccSecond: window.secondPeakScore,
                phatOffsetSeconds: window.phatOffsetSeconds, phatPeakRatio: window.phatPeakRatio,
                method: window.method ?? "", polarity: window.polarity, corroborations: window.corroborations,
                spectralWitness: window.spectralWitness)
        }
        let measured = try AdaptiveAlignment.regions(
            observations: observations, start: record.timing.measuredStart, end: record.timing.measuredEnd
        )
        let quietTiming = try AdaptiveQuietTiming.attaching(record.timing.quietTransitions ?? [], to: measured,
            targetChannels: record.target.channelCount,
            targetDuration: Double(record.target.sourceFrames) / Double(record.target.sourceRate),
            referenceDuration: Double(record.reference.sourceFrames) / Double(record.reference.sourceRate))
        let timing = try AnchoredTiming.recovering(quietTiming,
            observations: record.timing.anchoredRecovery?.observations ?? [])
        try #require(timing == record.timing, "current-version numeric replay must preserve the complete timing result")
        #expect(timing.attemptedWindows == record.windows.count)
        #expect(timing.regions.allSatisfy { $0.maximumResidualMilliseconds <= 1.000001 })
        let updated = AdaptiveAnalysisRecord(
            reference: record.reference, target: record.target, timing: timing, windows: record.windows,
            refusal: timing.regions.isEmpty ? "No supported local runs." : nil,
            referenceRevision: record.referenceRevision, referenceToAlignedRate: record.referenceToAlignedRate,
            referenceToAlignedOffset: record.referenceToAlignedOffset,
            referenceCoverageStart: record.referenceCoverageStart, referenceCoverageEnd: record.referenceCoverageEnd
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: url.appendingPathExtension("regrouped.json"), options: .withoutOverwriting)
        print("WWPAIR-REPLAY | runs=\(timing.regions.count); supportedSeconds=\(timing.supportedSeconds); "
            + "usable=\(timing.usableWindows)/\(timing.attemptedWindows); mediaReads=0; no timing accepted")
    }
}
