import Foundation
import Testing
import WWAlignEstimate
@testable import WWAutoAlign

@Suite("Automatic estimator purity and bounds")
struct AutomaticPurityTests {
    @Test func sourceHasNoContentOrApprovalSurface() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/WWAutoAlign")
        let forbidden = ["FileManager", "FileHandle", "Data(contentsOf:", "String(contentsOf:", "URLSession", "URL(", "AVAudio", "SourceDecoder",
                         "SystemSourceContentIO", "Process(", "clockApproved", "ClockApproval", "JSONDecoder", "Task.detached", "Task {"]
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            for token in forbidden { #expect(!code.contains(token), "\(file.lastPathComponent): \(token)") }
        }
    }

    @Test func tinyFeatureBuffersAreExplicitlyEmpty() throws {
        let buffer = try SampleBuffer(samples: [0.1], sampleRate: 8000)
        #expect(try Signal(buffer).features().allSatisfy(\.isEmpty))
    }
}
