import AudioToolbox
import Foundation
import Testing
import WWCore
@testable import WWMix

@Suite("Native Audio Unit hosting", .serialized)
struct NativeAudioUnitTests {
    func slot(_ subtype: OSType = kAudioUnitSubType_LowPassFilter) -> AudioUnitSlot {
        .init(component: .init(type: kAudioUnitType_Effect, subtype: subtype,
            manufacturer: kAudioUnitManufacturer_Apple))
    }

    @Test @MainActor func discoversAppleEffectsWithoutLoadingEditors() {
        #expect(MixerAudioUnits.installedEffects().contains {
            $0.identity.subtype == kAudioUnitSubType_LowPassFilter
                && $0.identity.manufacturer == kAudioUnitManufacturer_Apple
        })
        #expect(MixerAudioUnits.installedEffects().allSatisfy { $0.identity.isValid })
    }

    @Test func appleMonoAndStereoRenderAndRecallOpaqueDocumentState() async throws {
        for channels in [1, 2] {
            let unit = try await NativeAudioUnit.load(slot(), channels: channels, policy: .init())
            #expect(unit.status.channels == channels)
            let parameters = try unit.parameters()
            let cutoff = try #require(parameters.first { $0.address == UInt64(kLowPassParam_CutoffFrequency) })
            try unit.setParameter(address: cutoff.address, value: 1700)
            let captured = try unit.capture()
            #expect(captured.isValid)
            #expect(try unit.capture().documentState == captured.documentState)
            let recalled = try await NativeAudioUnit.load(captured, channels: channels, policy: .init())
            let recalledParameters = try recalled.parameters()
            #expect(try #require(recalledParameters.first { $0.address == cutoff.address }).value == 1700)
            let samples = Array(repeating: (0..<512).map { Float(sin(Double($0) * 0.2)) * 0.25 }, count: channels)
            let rendered = try recalled.render(samples)
            #expect(rendered.count == channels && rendered.allSatisfy { $0.count == 512 })
            #expect(rendered.flatMap { $0 }.allSatisfy { $0.isFinite })
            #expect(rendered[0] != samples[0])
        }
    }

    @Test func missingAndInvalidUnitsNeverTurnIntoDrySuccess() async throws {
        let missing = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect,
            subtype: 0x57574E4F, manufacturer: 0x57574E4F))
        await #expect(throws: MixerFailure.missingUnit(missing.id)) {
            try await NativeAudioUnit.load(missing, channels: 1, policy: .init())
        }
        await #expect(throws: MixerFailure.self) {
            try await NativeAudioUnit.load(slot(), channels: 3, policy: .init())
        }
        var bypassed = missing
        bypassed.bypassed = true
        await #expect(throws: MixerFailure.missingUnit(missing.id)) {
            try await NativeAudioUnit.load(bypassed, channels: 1, policy: .init())
        }
    }

    @Test func bypassIsExplicitDryAndParameterBoundsAreEnforced() async throws {
        var bypassed = slot()
        bypassed.bypassed = true
        let unit = try await NativeAudioUnit.load(bypassed, channels: 1, policy: .init())
        let samples: [[Float]] = [[0.25, -0.25, 0.1]]
        #expect(try unit.render(samples) == samples)
        #expect(unit.status.bypassed && unit.status.latencyFrames == 0)
        #expect(throws: MixerFailure.parameter(bypassed.id)) {
            try unit.setParameter(address: UInt64(kLowPassParam_CutoffFrequency), value: .nan)
        }
        #expect(throws: MixerFailure.parameter(bypassed.id)) {
            try unit.setParameter(address: UInt64.max, value: 1)
        }
    }

    @Test func reportedAppleTailIsRenderedBeyondTheExactProgramOnlyWhenRequested() async throws {
        let f = MixFixture()
        var episode = f.episode
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1, inserts: [slot()])])
        let recipe = try f.recipe(episode, frames: 0..<7, policy: .init(tail: .includeReported))
        let processor = try await MixerProcessor.load(recipe: recipe)
        let status = try #require(await processor.unitStatuses().first)
        #expect(status.tailFrames > 0)
        let output = try await processor.process(.init(frames: 0..<7,
            channels: [recipe.routes[0].reference: [0, 0, 0, 0, 0, 0, 0.5]]))
        #expect(output.frameCount == 7)
        var tail: [Float] = []
        while let output = try await processor.finishNext() { tail += output.channels[0] }
        #expect(tail.count == status.tailFrames)
        #expect(tail.contains { abs($0) > 0.000_001 })
    }
}
