import Foundation
import Testing
import WWCore
@testable import WWMix

/// Opt-in, generated PCM only. No engine, device, recording, editor, or saved vendor state is opened.
@Suite("Approved synthetic Waves timing", .serialized)
struct WavesSyntheticTimingTests {
    private struct Timing: Encodable {
        let name: String
        let blocks: Int
        let firstMilliseconds: Double
        let averageMilliseconds: Double
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
        let blockBudgetMilliseconds: Double
        let loadedInProcess: [Bool]
    }

    private enum Failure: Error {
        case wallTimeBudgetExceeded
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_WAVES_SYNTHETIC_TIMING"] == "1",
        "Requires explicit approval to benchmark the installed Waves effects on this physical Mac."))
    func installedFactoryEffectsAndTheTwoSpeakerMasterChain() async throws {
        let names = ["RCompressor (m)", "TrueVerb (m)", "L1 limiter (s)"]
        let components = await MixerAudioUnits.installedEffects()
        let effects = try names.map { name in
            try #require(components.first {
                $0.manufacturer.localizedCaseInsensitiveContains("Waves")
                    && ($0.name == name || $0.name.hasSuffix(": \(name)"))
            }, Comment(rawValue: "Installed effect not found: \(name)"))
        }
        func slot(_ component: MixerComponent) -> AudioUnitSlot {
            AudioUnitSlot(component: component.identity, productName: component.name)
        }
        let block = MixerLiveTiming.processingBlockFrames
        let samples = (0..<block).map { Float(sin(Double($0) * 2 * .pi / Double(block))) * 0.1 }
        let blocks = 120
        for (index, effect) in effects.enumerated() {
            let channels = index == 2 ? 2 : 1
            let unit = try await NativeAudioUnit.load(slot(effect), channels: channels, policy: .init())
            let input = Array(repeating: samples, count: channels)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var elapsed: [Double] = []
            for _ in 0..<blocks {
                guard ContinuousClock.now < deadline else { throw Failure.wallTimeBudgetExceeded }
                let start = ContinuousClock.now
                let output = try unit.render(input)
                elapsed.append(milliseconds(ContinuousClock.now - start))
                #expect(output.count == channels && output.allSatisfy { $0.count == block })
            }
            try report(effect.name, elapsed: elapsed, loadedInProcess: [unit.status.loadedInProcess])
        }
        let fixture = MixFixture()
        let second = SpeakerID()
        var episode = fixture.episode
        episode.speakerAssignments.append(.init(speakerID: second,
            primary: .init(sourceID: fixture.backup.id, statedChannel: 0), primaryConfirmation: .userConfirmed))
        episode.mix = .init(speakers: [
            .init(speaker: fixture.speaker, inserts: [slot(effects[0])]),
            .init(speaker: second, inserts: [slot(effects[1])])
        ], master: .init(inserts: [slot(effects[2])]))
        let recipe = try fixture.recipe(episode, frames: 0..<Int64(block * blocks))
        let processor = try await MixerProcessor.load(recipe: recipe)
        let input = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.reference, samples) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var elapsed: [Double] = []
        var emitted = 0
        for index in 0..<blocks {
            guard ContinuousClock.now < deadline else { throw Failure.wallTimeBudgetExceeded }
            let first = Int64(index * block)
            let start = ContinuousClock.now
            let output = try await processor.process(.init(frames: first..<(first + Int64(block)), channels: input))
            elapsed.append(milliseconds(ContinuousClock.now - start))
            emitted += output.frameCount
        }
        while let output = try await processor.finishNext() { emitted += output.frameCount }
        #expect(emitted == blocks * block)
        let statuses = await processor.unitStatuses()
        try report("RCompressor + TrueVerb speaker buses -> L1 stereo Master",
            elapsed: elapsed, loadedInProcess: statuses.map(\.loadedInProcess))
    }

    private func milliseconds(_ value: Duration) -> Double {
        let parts = value.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private func report(_ name: String, elapsed: [Double], loadedInProcess: [Bool]) throws {
        let sorted = elapsed.sorted()
        let timing = Timing(name: name, blocks: elapsed.count, firstMilliseconds: elapsed[0],
            averageMilliseconds: elapsed.reduce(0, +) / Double(elapsed.count),
            medianMilliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
            maximumMilliseconds: sorted[sorted.count - 1],
            blockBudgetMilliseconds: Double(MixerLiveTiming.processingBlockFrames) / 48,
            loadedInProcess: loadedInProcess)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("WAVES_SYNTHETIC_TIMING \(String(decoding: try encoder.encode(timing), as: UTF8.self))")
    }
}
