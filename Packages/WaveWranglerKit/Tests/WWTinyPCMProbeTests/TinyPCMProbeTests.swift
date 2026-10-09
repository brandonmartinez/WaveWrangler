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
