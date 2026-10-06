import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

/// A smooth, band-limited-enough test signal that differs per occurrence and channel.
func toneSample(_ occurrence: SourceOccurrenceID, _ channel: Int, _ frame: Int64) -> Float {
    let salt = Double(occurrence.hashValue & 0xFF) / 256
    return Float(0.5 * sin(0.01 * Double(frame) * Double(channel + 1) + salt))
}

/// One occurrence on one epoch with one segment: aligned t = a (n/F + e) + b.
struct SingleSpan {
    let epoch = RecordingEpochID()
    let id = SourceOccurrenceID()
    let map: GroupTimeMap

    init(rate f: Int64, frames: Int64, a: ExactRational = .one, b: ExactRational = .zero, e: ExactRational = .zero) throws {
        map = try groupMap(
            epochs: [mapped(epoch, [seg(q(-10), q(10_000), a, b)])],
            placements: [OccurrencePlacement(occurrence: occurrence(id, frames: frames, rate: f), spans: [span(0, frames, epoch, e: e)])]
        )
    }

    func request(_ g: Int64, _ frames: Range<Int64>, channels count: Int, recipe: RenderRecipe = .m2Candidate) -> RenderRequest {
        RenderRequest(groupMap: map, outputRate: rate(g), outputFrames: frames, channels: channels(id, count), inputAssets: assets([id]), recipe: recipe)
    }
}

@Suite("Render behaviour")
struct RenderBehaviourTests {
    /// Unit ratio at an integer phase is an exact copy, including an explicit integer delay; frames
    /// outside coverage are exactly zero.
    @Test func identityAndIntegerDelayAreBitExact() async throws {
        let fixture = try SingleSpan(rate: 48000, frames: 5000, b: q(100, 48000))
        let input = (0 ..< 3).map { c in (0 ..< 5000).map { toneSample(fixture.id, c, Int64($0)) } }
        let result = try await renderToArrays(fixture.request(48000, -200 ..< 5300, channels: 3), provider: ArrayProvider(buffers: [fixture.id: input]))
        for c in 0 ..< 3 {
            let out = result.product[c]
            #expect(out.count == 5500)
            #expect(out[0 ..< 300].allSatisfy { $0 == 0 })              // k < 100: outside coverage
            #expect(Array(out[300 ..< 5300]) == input[c])                // y(k) = x(k - 100), bitwise
            #expect(out[5300...].allSatisfy { $0 == 0 })
        }
        let runs = result.manifest.occurrences[0].runs.map(\.content)
        #expect(runs == [.padding(.outsideCoverage), runs[1], .padding(.outsideCoverage)])
    }

    /// A unit ratio with a fractional offset is never a copy: a half-frame delay interpolates to the
    /// analytic tone at k − 100.5, not to either neighbouring integer shift.
    @Test func unitRatioWithFractionalDelayInterpolates() async throws {
        let fixture = try SingleSpan(rate: 48000, frames: 5000, b: q(201, 96000))
        let input = (0 ..< 2).map { c in (0 ..< 5000).map { toneSample(fixture.id, c, Int64($0)) } }
        let result = try await renderToArrays(fixture.request(48000, 0 ..< 5000, channels: 2), provider: ArrayProvider(buffers: [fixture.id: input]))
        let salt = Double(fixture.id.hashValue & 0xFF) / 256
        for c in 0 ..< 2 {
            var worst = 0.0
            for k in 400 ..< 4600 {
                let expected = 0.5 * sin(0.01 * (Double(k) - 100.5) * Double(c + 1) + salt)
                worst = max(worst, abs(Double(result.product[c][k]) - expected))
            }
            #expect(worst < 1e-4, "channel \(c) worst \(worst)")
        }
    }

    /// Padding is exact zero, never the input; every frame the provider is asked for lies inside one span;
    /// requests per occurrence ascend without overlap (each frame requested once).
    @Test func paddingIsExactZeroAndRequestsStayInsideSpans() async throws {
        let fixture = try MixedGroup()
        let provider = FunctionProvider { _, _, _ in 1 }
        let request = fixture.request(channelsA: 2, channelsB: 1)
        let result = try await GroupRenderer.render(request, provider: provider) { _ in CollectingSink() }
        for record in result.manifest.occurrences {
            let outputs = result.manifest.channels.indices.filter { result.manifest.channels[$0].occurrence == record.occurrence }
            for run in record.runs {
                let range = Int(run.outputStart - result.manifest.outputStartFrame) ..< Int(run.outputEnd - result.manifest.outputStartFrame)
                for c in outputs {
                    let values = result.product[c][range]
                    if case .padding = run.content {
                        #expect(values.allSatisfy { $0 == 0 && $0.sign == .plus }, "padding run \(run)")
                    } else {
                        #expect(values.allSatisfy { $0.isFinite && $0 != 0 })
                    }
                }
            }
            let placement = try #require(fixture.map.placements.first { $0.occurrence.id == record.occurrence })
            let mine = provider.recorded.filter { $0.occurrence == record.occurrence }
            #expect(!mine.isEmpty)
            for (left, right) in zip(mine, mine.dropFirst()) { #expect(left.frames.upperBound <= right.frames.lowerBound) }
            for request in mine {
                #expect(request.decodedChannels == record.decodedChannels && request.source == record.source)
                #expect(placement.spans.contains { $0.startFrame <= request.frames.lowerBound && request.frames.upperBound <= $0.endFrame }, "\(request.frames)")
                #expect(!placement.spans.contains { span in
                    if case .unsupported? = fixture.map.epochs.first(where: { $0.epoch == span.epoch })?.mapping {
                        return span.startFrame < request.frames.upperBound && request.frames.lowerBound < span.endFrame
                    }
                    return false
                }, "unsupported frames requested: \(request.frames)")
            }
        }
        #expect(result.report.providerRequests == provider.recorded.count)
        #expect(result.report.providerFrames == provider.recorded.reduce(0) { $0 + Int64($1.frames.count) })
    }

    /// Taps never cross a span boundary: changing every sample of one span leaves the output rendered
    /// from the adjacent spans bitwise unchanged.
    @Test func tapsNeverCrossSpanBoundaries() async throws {
        let e1 = RecordingEpochID()
        let e2 = RecordingEpochID()
        let id = SourceOccurrenceID()
        // Two back-to-back spans of different epochs, both a = 1.0003, continuous on the output timeline:
        // span 2 starts one source frame period after span 1 ends (t = a n / 48000 throughout).
        let a = q(10003, 10000)
        let map = try groupMap(
            epochs: [mapped(e1, [seg(q(0), q(1, 24), a, .zero)]), mapped(e2, [seg(try q(5).adding(q(1, 24)), q(6), a, try q(-5).multiplied(by: a))])],
            placements: [OccurrencePlacement(occurrence: occurrence(id, frames: 4000, rate: 48000), spans: [span(0, 2000, e1), span(2000, 4000, e2, e: q(5))])]
        )
        let request = RenderRequest(groupMap: map, outputRate: rate(48000), outputFrames: 0 ..< 4100, channels: channels(id, 2), inputAssets: assets([id]))
        let base = try await renderToArrays(request, provider: FunctionProvider { o, c, n in toneSample(o, c, n) })
        let changed = try await renderToArrays(request, provider: FunctionProvider { o, c, n in n >= 2000 ? 0.9 : toneSample(o, c, n) })
        let changedFirst = try await renderToArrays(request, provider: FunctionProvider { o, c, n in n < 2000 ? -0.9 : toneSample(o, c, n) })
        let sourceRuns = base.manifest.occurrences[0].runs.filter { if case .source = $0.content { true } else { false } }
        #expect(sourceRuns.count == 2)
        let first = Int(sourceRuns[0].outputStart) ..< Int(sourceRuns[0].outputEnd)
        let second = Int(sourceRuns[1].outputStart) ..< Int(sourceRuns[1].outputEnd)
        for c in 0 ..< 2 {
            #expect(base.product[c][first] == changed.product[c][first])
            #expect(base.product[c][second] != changed.product[c][second])
            #expect(base.product[c][second] == changedFirst.product[c][second])
            #expect(base.product[c][first] != changedFirst.product[c][first])
        }
    }

    /// Output samples do not depend on the chunk size.
    @Test(arguments: [64, 1000, 4096, 65536])
    func chunkingNeverChangesSamples(chunk: Int) async throws {
        let fixture = try MixedGroup()
        let generate: FunctionProvider.Generator = { o, c, n in toneSample(o, c, n) }
        let reference = try await renderToArrays(fixture.request(), provider: FunctionProvider(generate))
        let request = RenderRequest(groupMap: fixture.map, outputRate: rate(48000), outputFrames: -100 ..< 29000, channels: channels(fixture.a, 2) + channels(fixture.b, 1), inputAssets: assets([fixture.a, fixture.b]), recipe: recipe(chunk: chunk))
        let chunked = try await renderToArrays(request, provider: FunctionProvider(generate))
        #expect(chunked.product == reference.product)
        #expect(chunked.report.chunks == (29100 + chunk - 1) / chunk)
    }

    /// One transform, one phase per frame, for every channel: identical inputs give bitwise-identical
    /// outputs, in request order, whatever the channel order and grouping.
    @Test func identicalChannelsRenderIdentically() async throws {
        let fixture = try SingleSpan(rate: 44100, frames: 20000, a: q(10007, 10000), b: q(1, 3), e: q(-1, 7))
        let ids = [3, 0, 5, 1, 4, 2]
        let request = RenderRequest(
            groupMap: fixture.map, outputRate: rate(48000), outputFrames: 15000 ..< 40000,
            channels: ids.map { RenderChannel(occurrence: fixture.id, decodedChannel: $0, statedChannel: .known($0)) },
            inputAssets: assets([fixture.id])
        )
        let result = try await renderToArrays(request, provider: FunctionProvider { _, _, n in toneSample(fixture.id, 0, n) })
        #expect(result.manifest.occurrences[0].decodedChannels == [0, 1, 2, 3, 4, 5])
        for c in 1 ..< 6 { #expect(result.product[c] == result.product[0]) }
        // Distinct channels keep their identity (no swap): route order follows the request.
        let distinct = try await renderToArrays(request, provider: FunctionProvider { _, c, _ in Float(c + 1) / 8 })
        for (index, channel) in ids.enumerated() {
            let steady = distinct.product[index][200 ..< 1000]
            #expect(steady.allSatisfy { abs($0 - Float(channel + 1) / 8) < 1e-6 }, "output \(index) is not decoded channel \(channel)")
        }
    }

    /// Decoding, alignment and rendering never run on the main thread, even when awaited from it.
    @MainActor
    @Test func rendersOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0)
        let fixture = try MixedGroup()
        let provider = FunctionProvider { o, c, n in toneSample(o, c, n) }
        let events = EventLog()
        let result = try await GroupRenderer.render(fixture.request(), provider: provider) { _ in CollectingSink(events: events) }
        #expect(provider.calledOnMain.withLock { !$0 })
        #expect(!events.events.contains("main"))
        #expect(events.events.last == "finish" && result.report.chunks == 8)
    }

    /// The decoded window is bounded by the chunk, the ratio and the kernel, not by the render length.
    @Test func workingSetIsBounded() async throws {
        let fixture = try SingleSpan(rate: 96000, frames: 80_000, a: q(9999, 10000))
        let result = try await renderToArrays(fixture.request(48000, 0 ..< 36_000, channels: 2), provider: FunctionProvider { _, _, _ in 0.25 })
        let manifest = result.manifest
        guard case .source(let run) = manifest.occurrences[0].runs[0].content else { Issue.record("no source run"); return }
        let step = run.sourceFramesPerOutputFrame.approximateDouble
        let halfTaps = Int((32 * step).rounded(.up))
        let windowBound = Int((Double(4096) * step).rounded(.up)) + 2 * halfTaps + 2
        #expect(result.report.peakWindowFrames <= windowBound)
        #expect(result.report.peakWorkingSetBytes <= 2 * windowBound * 4 + 2 * 4096 * 4 + 2 * halfTaps * 8)
        #expect(result.report.chunks == 9)
        #expect(result.report.providerFrames > 8 * Int64(windowBound))
        #expect(result.report.providerFrames <= 80_000)
    }
}

@Suite("Render failures")
struct RenderFailureTests {
    func render(_ provider: FunctionProvider, events: EventLog, failAtChunk: Int? = nil) async -> RenderFailure? {
        do {
            _ = try await GroupRenderer.render(try MixedGroup().request(), provider: provider) { _ in CollectingSink(events: events, failAtChunk: failAtChunk) }
            return nil
        } catch let failure as RenderFailure {
            return failure
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    func expectAbandoned(_ events: EventLog) {
        #expect(events.events.last == "abandon")
        #expect(!events.events.contains("finish"))
        #expect(events.events.filter { $0 == "abandon" }.count == 1)
    }

    @Test func providerFailureAbandons() async {
        let events = EventLog()
        let failure = await render(FunctionProvider(failAtRequest: 2) { _, _, _ in 0.1 }, events: events)
        #expect(failure.map { if case .providerFailed = $0 { true } else { false } } == true)
        expectAbandoned(events)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonFiniteInputIsRefused(bad: Float) async {
        let events = EventLog()
        let provider = FunctionProvider(mutate: { samples in samples[samples.count - 1][samples[0].count / 2] = bad }) { _, _, _ in 0.1 }
        let failure = await render(provider, events: events)
        #expect(failure.map { if case .nonFiniteInput = $0 { true } else { false } } == true)
        expectAbandoned(events)
    }

    @Test func wrongShapeIsRefused() async {
        typealias Mutation = @Sendable (inout [[Float]]) -> Void
        let mutations: [Mutation] = [
            { samples in samples[0].removeLast() },
            { samples in samples.removeLast() },
            { samples in samples.append(Array(repeating: 0, count: samples[0].count)) },
            { samples in samples[0].append(0) },
        ]
        for mutate in mutations {
            let events = EventLog()
            let failure = await render(FunctionProvider(mutate: mutate) { _, _, _ in 0.1 }, events: events)
            #expect(failure.map { if case .providerShapeMismatch = $0 { true } else { false } } == true)
            expectAbandoned(events)
        }
    }

    @Test func sinkFailureAbandons() async {
        let events = EventLog()
        let failure = await render(FunctionProvider { _, _, _ in 0.1 }, events: events, failAtChunk: 3)
        #expect(failure.map { if case .sinkFailed = $0 { true } else { false } } == true)
        expectAbandoned(events)
        #expect(events.events.filter { $0 == "append" }.count == 3)
    }

    @Test func sinkCreationFailureReadsNothing() async throws {
        struct NoSink: Error {}
        let provider = FunctionProvider { _, _, _ in 0.1 }
        await #expect(throws: RenderFailure.sinkFailed(String(describing: NoSink()))) {
            _ = try await GroupRenderer.render(try MixedGroup().request(), provider: provider) { _ throws -> CollectingSink in throw NoSink() }
        }
        #expect(provider.recorded.isEmpty)
    }

    @Test func invalidRequestReadsNothingAndMakesNoSink() async throws {
        let fixture = try MixedGroup()
        let provider = FunctionProvider { _, _, _ in 0.1 }
        let events = EventLog()
        await #expect(throws: RenderFailure.emptyChannelList) {
            _ = try await GroupRenderer.render(RenderRequest(groupMap: fixture.map, outputRate: rate(48000), outputFrames: 0 ..< 10, channels: [], inputAssets: []), provider: provider) { _ in
                events.append("made")
                return CollectingSink(events: events)
            }
        }
        #expect(provider.recorded.isEmpty && events.events.isEmpty)
    }

    /// Cancellation mid-render (deterministically, from inside the provider) abandons without finishing.
    @Test func cancellationMidRenderAbandons() async throws {
        let events = EventLog()
        let provider = FunctionProvider(mutate: { _ in withUnsafeCurrentTask { $0?.cancel() } }) { _, _, _ in 0.1 }
        let fixture = try MixedGroup()
        let failure = await Task { () -> RenderFailure? in
            do throws(RenderFailure) {
                _ = try await GroupRenderer.render(fixture.request(), provider: provider) { _ in CollectingSink(events: events) }
                return nil
            } catch {
                return error
            }
        }.value
        #expect(failure == .cancelled)
        expectAbandoned(events)
        #expect(provider.recorded.count == 1)
    }

    @Test func cancellationBeforeStartReadsNothing() async throws {
        let events = EventLog()
        let provider = FunctionProvider { _, _, _ in 0.1 }
        let fixture = try MixedGroup()
        let failure = await Task { () -> RenderFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(RenderFailure) {
                _ = try await GroupRenderer.render(fixture.request(), provider: provider) { _ in CollectingSink(events: events) }
                return nil
            } catch {
                return error
            }
        }.value
        #expect(failure == .cancelled)
        #expect(provider.recorded.isEmpty && events.events.isEmpty)
    }
}
