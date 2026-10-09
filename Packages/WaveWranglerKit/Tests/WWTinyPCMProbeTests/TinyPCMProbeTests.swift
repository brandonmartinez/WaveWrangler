import Darwin
import Foundation
import Testing
@testable import WWTinyPCMProbe

@Suite("WW-026 opt-in generated-PCM probe")
struct TinyPCMProbeTests {
    @Test func absentModelRefuses() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(throws: ProbeError.missingModel) {
            try TinyModelProbe.run(path: missing)
        }
    }

    @Test func wrongSizeAndSameSizeWrongHashRefuse() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0]).write(to: file)
        #expect(throws: ProbeError.invalidSize) {
            try TinyModelProbe.run(path: file.path)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 77_704_715)
        try handle.close()
        #expect(throws: ProbeError.hashMismatch) {
            try TinyModelProbe.run(path: file.path)
        }
    }

    @Test func symlinkAndDirectoryRefuseBeforeRead() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try Data([0]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ProbeError.invalidInput) { try TinyModelProbe.run(path: link.path) }
        #expect(throws: ProbeError.invalidInput) {
            try TinyModelProbe.run(path: FileManager.default.temporaryDirectory.path)
        }
    }

    @Test func descriptorReadFailureRefusesWithoutHashingOrInference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 77_704_715)
        try handle.close()

        var attempts = 0
        #expect(throws: ProbeError.readFailed) {
            try TinyModelProbe.readModel(path: file.path, descriptorRead: { _, _, _, _ in
                attempts += 1
                errno = attempts == 1 ? EINTR : EIO
                return -1
            })
        }
        #expect(attempts == 2)
        attempts = 0
        #expect(throws: ProbeError.readFailed) {
            try TinyModelProbe.readModel(path: file.path, descriptorRead: { _, _, _, _ in
                attempts += 1
                errno = EINTR
                return -1
            })
        }
        #expect(attempts == 9)
        #expect(throws: ProbeError.invalidSize) {
            try TinyModelProbe.readModel(path: file.path, descriptorRead: { _, _, _, _ in 0 })
        }
    }

    @Test func nonlocalOrUnknownFilesystemRefusesBeforeContentRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0]).write(to: file)

        #expect(throws: ProbeError.nonLocalFilesystem) {
            try TinyModelProbe.readModel(path: file.path, fileSystemStatus: { _, status in
                status.pointee.f_flags = 0
                return 0
            }, descriptorRead: { _, _, _, _ in
                Issue.record("Nonlocal descriptor was read")
                return -1
            })
        }
        #expect(throws: ProbeError.filesystemStatusUnavailable) {
            try TinyModelProbe.readModel(path: file.path, fileSystemStatus: { _, _ in -1 },
                                         descriptorRead: { _, _, _, _ in
                Issue.record("Descriptor was read without filesystem provenance")
                return -1
            })
        }
    }

    @Test func nativeTokenTimingClassificationNeverProducesSupportedWordEvidence() {
        #expect(TinyModelProbe.classifyTokenTiming(enabled: false, start: 10, end: 20) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: -1, end: -1) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: -1, end: 20) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: 10, end: -1) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: 20, end: 10) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: 10, end: 10) == "absent")
        #expect(TinyModelProbe.classifyTokenTiming(enabled: true, start: 0, end: 20) ==
                "experimental/unsupported")
    }

    @Test func generatedProbeJSONHasOnlyAggregateUnsupportedTokenEvidence() throws {
        let disabled = TinyTokenTimingObservation(
            mode: "disabled", provenance: "experimental/unsupported", tokenCount: 4,
            textTokenCount: 3, absentTextTokenCount: 3, experimentalTextTokenCount: 0,
            leadingWhitespaceTokenCount: 1, internalWhitespaceTokenCount: 0,
            unseparatedAdjacentTokenCount: 1
        )
        let enabled = TinyTokenTimingObservation(
            mode: "experimental-enabled", provenance: "experimental/unsupported", tokenCount: 4,
            textTokenCount: 3, absentTextTokenCount: 2, experimentalTextTokenCount: 1,
            leadingWhitespaceTokenCount: 1, internalWhitespaceTokenCount: 0,
            unseparatedAdjacentTokenCount: 1
        )
        let result = TinyProbeResult(
            loaded: true, inferred: true, sampleCount: 32_000, threads: 2,
            segmentCount: 1, whitespaceWordCount: 2, segmentTimingAvailable: true,
            loadSeconds: 0.25, inferenceSeconds: 0.5, enabledInferenceSeconds: 0.75,
            tokenTimingDisabled: disabled, tokenTimingEnabled: enabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(decoding: encoder.encode(result), as: UTF8.self)
        let expectedDisabled = #"{"absentTextTokenCount":3,"experimentalTextTokenCount":0,"internalWhitespaceTokenCount":0,"leadingWhitespaceTokenCount":1,"mode":"disabled","provenance":"experimental/unsupported","textTokenCount":3,"tokenCount":4,"unseparatedAdjacentTokenCount":1}"#
        let expectedEnabled = #"{"absentTextTokenCount":2,"experimentalTextTokenCount":1,"internalWhitespaceTokenCount":0,"leadingWhitespaceTokenCount":1,"mode":"experimental-enabled","provenance":"experimental/unsupported","textTokenCount":3,"tokenCount":4,"unseparatedAdjacentTokenCount":1}"#
        #expect(json == #"{"enabledInferenceSeconds":0.75,"inferenceSeconds":0.5,"inferred":true,"loadSeconds":0.25,"loaded":true,"sampleCount":32000,"segmentCount":1,"segmentTimingAvailable":true,"supportedWordBoundaryCount":0,"threads":2,"tokenTimingDisabled":\#(expectedDisabled),"tokenTimingEnabled":\#(expectedEnabled),"whitespaceWordCount":2,"wordTimingAvailable":false,"wordTimingProvenance":"experimental/unsupported"}"#)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_TINY_MODEL_PATH"] != nil))
    func modelBackedSyntheticInferenceWhenExplicitlyOptedIn() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WW_TINY_MODEL_PATH"])
        let result = try TinyModelProbe.run(path: path)
        #expect(result.loaded)
        #expect(result.inferred)
        #expect(result.sampleCount == 32_000)
        #expect(result.threads == 2)
        #expect(result.loadSeconds >= 0)
        #expect(result.inferenceSeconds >= 0)
        #expect(result.enabledInferenceSeconds >= 0)
        #expect(result.whitespaceWordCount >= 0)
        #expect(result.wordTimingAvailable == false)
        #expect(result.supportedWordBoundaryCount == 0)
        #expect(result.tokenTimingDisabled.mode == "disabled")
        #expect(result.tokenTimingDisabled.experimentalTextTokenCount == 0)
        #expect(result.tokenTimingDisabled.absentTextTokenCount == result.tokenTimingDisabled.textTokenCount)
        #expect(result.tokenTimingEnabled.mode == "experimental-enabled")
        #expect(result.tokenTimingEnabled.absentTextTokenCount +
                result.tokenTimingEnabled.experimentalTextTokenCount ==
                result.tokenTimingEnabled.textTokenCount)
    }
}
