import Foundation
import Testing

/// WWAlignEstimate consumes decoded sample arrays only: no file, content, decode or mutation APIs, no
/// concurrency or main-actor work, no dependencies beyond Foundation, WWCore and WWTimeMap, and no route to a
/// clock approval. Its vocabulary never presents a score as a probability.
@Suite("Estimator purity")
struct EstimatorPurityTests {
    /// Mirrors ForbiddenAPITests.forbidden (WWSourcesTests/EngineTests.swift) and the WWTimeMap scan.
    static let forbidden = [
        "Data(contentsOf", "FileHandle", "InputStream", "fopen(", "open(", "read(", "mmap",
        ".write(to", "write(", "moveItem", "removeItem", "trashItem", "copyItem", "replaceItem", "linkItem",
        "setAttributes", "setResourceValue", "createFile", "createDirectory", "evictUbiquitousItem",
        "startDownloadingUbiquitousItem", "NSFileCoordinator", "AVAsset", "AVAudioFile", "AudioFileOpen",
        "ExtAudioFile", "QLThumbnail", "QuickLook", "CryptoKit", "SHA256", "CC_SHA", "Insecure.",
        "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues(",
        "URL(", "Date(", "DispatchQueue", "Task {", "Task.detached", "@MainActor", "Accelerate", "vDSP",
    ]

    /// No path to a clock approval: the estimator may not name the approval case, its types, or decode a
    /// provenance (decoding is the only other way a `clockApproved` value could be produced).
    static let approvalSurface = ["clockApproved", "ClockApproval", "ClockGateMeasurements", "IndependentClockReference", "Decoder", "Decodable", "Codable"]

    /// Scores are correlation coefficients, margins and fractions; never presented as chance of being right.
    static let vocabulary = ["probab", "confiden", "likelihood", "percent", "certain", "chance"]

    static let allowedImports = ["import Foundation", "import WWCore", "import WWTimeMap"]

    /// Strips comments, keeping code AND string literals (abstention detail text is user-facing).
    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return "" }
                return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")
    }

    static func violations(in source: String, fileName: String) -> [String] {
        let code = code(source)
        var found = (forbidden + approvalSurface).filter { code.contains($0) }.map { "\(fileName): \($0)" }
        let lower = code.lowercased()
        found += vocabulary.filter { lower.contains($0) }.map { "\(fileName): \($0)" }
        let imports = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ") || $0.hasPrefix("@_") }
        found += imports.filter { !allowedImports.contains($0) }.map { "\(fileName): \($0)" }
        return found
    }

    @Test func scannerDetectsViolations() {
        #expect(Self.violations(in: "let d = try Data(contentsOf: url)", fileName: "X.swift") == ["X.swift: Data(contentsOf"])
        #expect(Self.violations(in: "import AVFoundation", fileName: "X.swift") == ["X.swift: import AVFoundation"])
        #expect(Self.violations(in: "return .clockApproved(x)", fileName: "X.swift") == ["X.swift: clockApproved"])
        #expect(Self.violations(in: "let m = try JSONDecoder().decode(MapProvenance.self, from: d)", fileName: "X.swift") == ["X.swift: Decoder"])
        #expect(Self.violations(in: "let detail = \"92 percent Confidence\"", fileName: "X.swift") == ["X.swift: confiden", "X.swift: percent"])
        #expect(Self.violations(in: "// clockApproved and probability in a comment\nlet a = 1 // FileHandle", fileName: "X.swift").isEmpty)
    }

    @Test func wwAlignEstimateIsPure() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWAlignEstimate")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(Set(files.map(\.lastPathComponent)).isSuperset(of: ["AcousticEstimator.swift", "WindowCorrelator.swift", "ConsistencyFit.swift", "Signal.swift", "Inputs.swift", "Results.swift"]))
        var violations: [String] = []
        for file in files {
            violations += Self.violations(in: try String(contentsOf: file, encoding: .utf8), fileName: file.lastPathComponent)
        }
        #expect(violations.isEmpty, "\(violations)")
    }

}
