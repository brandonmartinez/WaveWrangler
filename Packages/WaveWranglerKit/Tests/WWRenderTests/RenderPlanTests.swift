import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

/// A group with two occurrences exercising multi-segment epochs, an unsupported epoch, a gap restart,
/// leading unsupported and trailing uncovered regions, and mixed 44.1/48 kHz inputs onto a 48 kHz grid.
struct MixedGroup {
    let e1 = RecordingEpochID()  // two segments: a = 1.0005 then a = 0.9995
    let e2 = RecordingEpochID()  // unsupported
    let e3 = RecordingEpochID()  // a = 1, offset
    let e4 = RecordingEpochID()  // a = 1/2
    let a = SourceOccurrenceID()
    let b = SourceOccurrenceID()
    let map: GroupTimeMap

    init() throws {
        let a1 = q(10005, 10000)
        let a2 = q(9995, 10000)
        let b1 = q(1, 100)
        // Continuity at u = 0.05: a1*0.05 + b1 = a2*0.05 + b2.
        let b2 = try a1.multiplied(by: q(5, 100)).adding(b1).subtracting(a2.multiplied(by: q(5, 100)))
        map = try groupMap(
            epochs: [
                mapped(e1, [seg(q(0), q(5, 100), a1, b1), seg(q(5, 100), q(2, 10), a2, b2)]),
                EpochClockMap(epoch: e2, mapping: .unsupported(.estimatorAbstained)),
                mapped(e3, [seg(q(13, 100), q(19, 100), .one, q(3, 10))]),
                mapped(e4, [seg(q(0), q(5, 100), q(1, 2), q(55, 100))]),
            ],
            placements: [
                OccurrencePlacement(occurrence: occurrence(a, frames: 9000, rate: 44100), spans: [
                    span(0, 4410, e1, e: q(1, 100)),
                    span(4410, 6000, e2),
                    span(6000, 8000, e3),
                    span(8000, 9000, e4, e: q(-18, 100)),
                ]),
                OccurrencePlacement(occurrence: occurrence(b, frames: 9000, rate: 48000), spans: [
                    span(0, 2000, e2),
                    span(2000, 9000, e1, e: try q(-2000, 48000).adding(q(2, 100))),
                ]),
            ]
        )
    }

    func request(_ frames: Range<Int64> = -100 ..< 29000, channelsA: Int = 2, channelsB: Int = 1) -> RenderRequest {
        RenderRequest(
            groupMap: map,
            outputRate: rate(48000),
            outputFrames: frames,
            channels: channels(a, channelsA) + channels(b, channelsB),
            inputAssets: assets([a, b])
        )
    }
}

/// Checks every output frame of every occurrence against the map's own inverse.
func assertPlanMatchesMap(_ manifest: RenderManifest, _ map: GroupTimeMap) throws {
    let g = manifest.outputRate.framesPerSecond
    let k0 = manifest.outputStartFrame
    let k1 = k0 + manifest.outputFrameCount
    for record in manifest.occurrences {
        var cursor = k0
        for run in record.runs {
            #expect(run.outputStart == cursor && run.outputEnd > run.outputStart)
            cursor = run.outputEnd
            for k in run.outputStart ..< run.outputEnd {
                let inverse = try map.sourceFrame(at: q(k, g), in: record.occurrence)
                switch run.content {
                case .source(let source):
                    let x = try source.firstSourcePosition.adding(source.sourceFramesPerOutputFrame.multiplied(by: q(k - run.outputStart)))
                    guard case .source(let position) = inverse, position.exactFrame == x, position.epoch == source.epoch else {
                        Issue.record("frame \(k): planned \(x) but map says \(inverse)")
                        return
                    }
                    #expect(position.frame >= source.spanStartFrame && position.frame <= source.spanEndFrame)
                case .padding(let reason):
                    let expected: RenderPaddingReason? = switch inverse {
                    case .source: nil
                    case .gap: .gap
                    case .unsupported(let region): .unsupportedEpoch(region.candidates[0].reason)
                    case .outsideCoverage: .outsideCoverage
                    }
                    guard expected == reason else {
                        Issue.record("frame \(k): padding \(reason) but map says \(inverse)")
                        return
                    }
                }
            }
        }
        #expect(cursor == k1)
    }
}

@Suite("Render plan")
struct RenderPlanTests {
    @Test func planMatchesTheMapInverseAtEveryOutputFrame() throws {
        let fixture = try MixedGroup()
        let manifest = try GroupRenderer.plan(fixture.request())
        try assertPlanMatchesMap(manifest, fixture.map)
        // Every kind of region is exercised.
        let contents = manifest.occurrences.flatMap(\.runs).map(\.content)
        #expect(contents.contains(.padding(.gap)))
        #expect(contents.contains(.padding(.unsupportedEpoch(.estimatorAbstained))))
        #expect(contents.contains(.padding(.outsideCoverage)))
        let sourceRuns = contents.compactMap { if case .source(let s) = $0 { s } else { nil } }
        #expect(Set(sourceRuns.map(\.segmentIndex)) == [0, 1])
        #expect(Set(sourceRuns.map(\.epoch)) == [fixture.e1, fixture.e3, fixture.e4])
    }

    /// Partial output ranges (cut inside runs and padding) plan the same frames identically.
    @Test func subrangesPlanConsistently() throws {
        let fixture = try MixedGroup()
        for range: Range<Int64> in [700 ..< 701, 4799 ..< 4801, 10000 ..< 21000, 26450 ..< 27100] {
            try assertPlanMatchesMap(try GroupRenderer.plan(fixture.request(range)), fixture.map)
        }
    }

    /// The manifest records the clock pitch 1/a and the exact frame ratio, never a stretch.
    @Test func manifestRecordsPitchRatioVersionsAndAssets() throws {
        let fixture = try MixedGroup()
        let manifest = try GroupRenderer.plan(fixture.request())
        #expect(manifest.rendererVersion == RenderVersions.renderer)
        #expect(manifest.outputAssetFormatVersion == RenderVersions.outputAssetFormat)
        #expect(manifest.recipe == .m2Candidate && manifest.recipe.version == RenderRecipe.currentVersion)
        #expect(manifest.group == fixture.map.group && manifest.reference == fixture.map.reference)
        #expect(manifest.outputStartFrame == -100 && manifest.outputFrameCount == 29100)
        #expect(manifest.occurrences.map(\.assetVersion) == ["decoded-v1/\(fixture.a)", "decoded-v1/\(fixture.b)"])
        for record in manifest.occurrences {
            for run in record.runs {
                guard case .source(let source) = run.content else { continue }
                #expect(try source.clockPitchFactor.multiplied(by: source.rateRatio) == .one)
                let expected = try q(record.nominalRate.framesPerSecond).divided(by: source.rateRatio.multiplied(by: q(48000)))
                #expect(source.sourceFramesPerOutputFrame == expected)
            }
        }
        let decoded = try JSONDecoder().decode(RenderManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
    }

    @Test func recipeCodingRevalidates() throws {
        let data = try JSONEncoder().encode(RenderRecipe.m2Candidate)
        #expect(try JSONDecoder().decode(RenderRecipe.self, from: data) == .m2Candidate)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["outputChunkFrames"] = 10
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RenderRecipe.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["outputChunkFrames"] = 4096
        object["version"] = 2
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RenderRecipe.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func recipeRejectsUnsafeParameters() {
        let k = RenderRecipe.m2Candidate.kernel
        func spec(h: Int = k.halfWidth, pass: Double = k.passbandEdge, stop: Double = k.stopbandEdge, beta: Double = k.kaiserBeta, phases: Int = k.tablePhasesPerSample) -> KaiserSincKernelSpec {
            KaiserSincKernelSpec(halfWidth: h, passbandEdge: pass, stopbandEdge: stop, kaiserBeta: beta, tablePhasesPerSample: phases)
        }
        for bad in [spec(h: 3), spec(h: 257), spec(pass: 0), spec(pass: 1.0, stop: 1.0), spec(stop: 1.01), spec(pass: .nan), spec(beta: -1), spec(beta: .infinity), spec(phases: 255), spec(phases: 65537)] {
            #expect(throws: RenderFailure.self) { try RenderRecipe(kernel: bad, outputChunkFrames: 4096) }
        }
        #expect(throws: RenderFailure.self) { try RenderRecipe(kernel: k, outputChunkFrames: 63) }
        #expect(throws: RenderFailure.self) { try RenderRecipe(kernel: k, outputChunkFrames: 65537) }
        #expect(throws: RenderFailure.self) { try RenderRecipe(kernel: k, outputChunkFrames: 4096, maximumDecimation: 0) }
        #expect(throws: RenderFailure.self) { try RenderRecipe(kernel: k, outputChunkFrames: 4096, maximumDecimation: 65) }
    }
}

@Suite("Render request validation")
struct RenderValidationTests {
    func expectFailure(_ expected: RenderFailure, _ request: RenderRequest) {
        #expect(throws: expected) { try GroupRenderer.plan(request) }
    }

    func with(_ fixture: MixedGroup, frames: Range<Int64> = 0 ..< 1000, channels: [RenderChannel], assets: [RenderInputAsset]? = nil, recipe: RenderRecipe = .m2Candidate) -> RenderRequest {
        RenderRequest(groupMap: fixture.map, outputRate: rate(48000), outputFrames: frames, channels: channels, inputAssets: assets ?? WWRenderTests.assets([fixture.a, fixture.b]).filter { asset in channels.contains { $0.occurrence == asset.occurrence } }, recipe: recipe)
    }

    @Test func refusesEmptyOrOversizedRanges() throws {
        let f = try MixedGroup()
        expectFailure(.invalidOutputRange, with(f, frames: 5 ..< 5, channels: channels(f.a, 1)))
        expectFailure(.invalidOutputRange, with(f, frames: 0 ..< RenderRequest.maximumOutputFrames + 1, channels: channels(f.a, 1)))
        expectFailure(.invalidOutputRange, with(f, frames: -RenderRequest.maximumOutputFrameMagnitude - 1 ..< 0, channels: channels(f.a, 1)))
        expectFailure(.invalidOutputRange, with(f, frames: RenderRequest.maximumOutputFrameMagnitude - 1 ..< RenderRequest.maximumOutputFrameMagnitude + 1, channels: channels(f.a, 1)))
        expectFailure(.emptyChannelList, with(f, channels: []))
    }

    @Test func refusesBadChannelRoutes() throws {
        let f = try MixedGroup()
        let stranger = SourceOccurrenceID()
        expectFailure(.unknownOccurrence(stranger), with(f, channels: [RenderChannel(occurrence: stranger, decodedChannel: 0, statedChannel: .unknown)], assets: []))
        let negative = RenderChannel(occurrence: f.a, decodedChannel: -1, statedChannel: .unknown)
        expectFailure(.invalidDecodedChannel(negative), with(f, channels: [negative]))
        let huge = RenderChannel(occurrence: f.a, decodedChannel: RenderRequest.maximumDecodedChannels, statedChannel: .unknown)
        expectFailure(.invalidDecodedChannel(huge), with(f, channels: [huge]))
        let duplicate = RenderChannel(occurrence: f.a, decodedChannel: 1, statedChannel: .unknown)
        expectFailure(.duplicateChannel(duplicate), with(f, channels: channels(f.a, 2) + [duplicate]))
        let swapped = RenderChannel(occurrence: f.a, decodedChannel: 0, statedChannel: .known(1))
        expectFailure(.statedChannelMismatch(swapped), with(f, channels: [swapped]))
        // Unknown stated channel is allowed (no claim to contradict); the same decoded channel of another
        // occurrence is a different route.
        #expect(throws: Never.self) { try GroupRenderer.plan(with(f, channels: [RenderChannel(occurrence: f.a, decodedChannel: 0, statedChannel: .unknown), RenderChannel(occurrence: f.b, decodedChannel: 0, statedChannel: .known(0))])) }
    }

    @Test func refusesBadInputAssets() throws {
        let f = try MixedGroup()
        let both = channels(f.a, 1) + channels(f.b, 1)
        expectFailure(.missingInputAsset(f.b), with(f, channels: both, assets: assets([f.a])))
        expectFailure(.duplicateInputAsset(f.a), with(f, channels: both, assets: assets([f.a, f.b, f.a])))
        expectFailure(.invalidInputAsset(f.b), with(f, channels: channels(f.a, 1), assets: assets([f.a, f.b])))
        expectFailure(.invalidInputAsset(f.a), with(f, channels: channels(f.a, 1), assets: [RenderInputAsset(occurrence: f.a, assetVersion: "  ")]))
    }

    @Test func refusesDecimationBeyondTheRecipe() throws {
        let epoch = RecordingEpochID()
        let id = SourceOccurrenceID()
        let map = try groupMap(epochs: [mapped(epoch, [seg(q(0), q(10), .one, .zero)])], placements: [OccurrencePlacement(occurrence: occurrence(id, frames: 96000, rate: 96000), spans: [span(0, 96000, epoch)])])
        let ok = RenderRequest(groupMap: map, outputRate: rate(1500), outputFrames: 0 ..< 1000, channels: channels(id, 1), inputAssets: assets([id]))
        #expect(throws: Never.self) { try GroupRenderer.plan(ok) }  // ratio exactly 64
        let tooFar = RenderRequest(groupMap: map, outputRate: rate(1000), outputFrames: 0 ..< 1000, channels: channels(id, 1), inputAssets: assets([id]))
        expectFailure(.ratioOutsideEnvelope(id, sourceFramesPerOutputFrame: q(96)), tooFar)
        let tighter = try RenderRecipe(kernel: RenderRecipe.m2Candidate.kernel, outputChunkFrames: 4096, maximumDecimation: 2)
        let decimate3 = RenderRequest(groupMap: map, outputRate: rate(32000), outputFrames: 0 ..< 1000, channels: channels(id, 1), inputAssets: assets([id]), recipe: tighter)
        expectFailure(.ratioOutsideEnvelope(id, sourceFramesPerOutputFrame: q(3)), decimate3)
    }

    /// A map at the WWTimeMap envelope (40-bit ratio, coprime ~2^20 rates, 2^30 frames) plans exactly.
    @Test func plansExactlyAtTheMapEnvelope() throws {
        let epoch = RecordingEpochID()
        let id = SourceOccurrenceID()
        let big = Int64(1) << 40
        let frames = Int64(1) << 30
        let map = try groupMap(
            epochs: [mapped(epoch, [seg(q(0), q(4096), q(big - 1, big - 3), q(1, (1 << 16) - 5))])],
            placements: [OccurrencePlacement(occurrence: occurrence(id, frames: frames, rate: 1_048_573), spans: [span(0, frames, epoch, e: q(7, (1 << 16) - 7))])]
        )
        let request = RenderRequest(groupMap: map, outputRate: rate(1_048_571), outputFrames: 0 ..< frames, channels: channels(id, 1), inputAssets: assets([id]))
        let manifest = try GroupRenderer.plan(request)
        let runs = manifest.occurrences[0].runs
        #expect(runs.count == 3)
        for run in runs {
            for k in [run.outputStart, run.outputEnd - 1] {
                let inverse = try map.sourceFrame(at: q(k, 1_048_571), in: id)
                switch run.content {
                case .source(let source):
                    let x = try source.firstSourcePosition.adding(source.sourceFramesPerOutputFrame.multiplied(by: q(k - run.outputStart)))
                    guard case .source(let position) = inverse else { Issue.record("\(k)"); continue }
                    #expect(position.exactFrame == x)
                case .padding(let reason):
                    #expect(reason == .outsideCoverage && inverse == .outsideCoverage)
                }
            }
        }
    }

    /// Run numerators that would leave Int128 are refused, never wrapped or approximated (one case per
    /// overflow check: denominator, position, step, count term, final sum).
    @Test func runNumeratorsRefuseOverflow() throws {
        func r(_ n: Int128, _ d: Int128) throws -> ExactRational { try ExactRational(numerator: n, denominator: d) }
        let m61 = (Int128(1) << 61) - 1  // prime
        let m31 = (Int128(1) << 31) - 1  // prime
        let (n, s, d) = try runNumerators(try r(5, m61), try r(3, m31), count: 1 << 40)
        #expect(d == m61 * m31 && n == 5 * m31 && s == 3 * m61)
        let m89 = (Int128(1) << 89) - 1  // prime
        #expect(throws: RenderFailure.arithmeticEnvelopeExceeded) { try runNumerators(try r(1, m89), try r(1, m61), count: 2) }
        #expect(throws: RenderFailure.arithmeticEnvelopeExceeded) { try runNumerators(try r(Int128(1) << 100, m31), try r(1, m61), count: 2) }
        #expect(throws: RenderFailure.arithmeticEnvelopeExceeded) { try runNumerators(try r(1, m61), try r(Int128(1) << 100, m31), count: 2) }
        #expect(throws: RenderFailure.arithmeticEnvelopeExceeded) { try runNumerators(try r(1, m61), try r((Int128(1) << 70) + 1, m61), count: 1 << 62) }
        #expect(throws: RenderFailure.arithmeticEnvelopeExceeded) { try runNumerators(try r(Int128.max - 1, 1), try r(2, 1), count: 2) }
        // Exactly representable extremes pass.
        #expect(throws: Never.self) { try runNumerators(try r(Int128.max - 2, 1), try r(2, 1), count: 2) }
        #expect(throws: Never.self) { try runNumerators(try r(1, m61), try r((Int128(1) << 60) + 1, m61), count: 1 << 62) }
    }
}
