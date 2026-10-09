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
        #expect(result.wordCount >= 0)
    }
}
