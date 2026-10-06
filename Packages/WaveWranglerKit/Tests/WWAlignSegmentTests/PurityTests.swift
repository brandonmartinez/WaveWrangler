import Foundation
import Testing

/// WWAlignSegment consumes decoded sample arrays and the frozen estimator's public API only: no file, content,
/// decode or mutation APIs, no concurrency or main-actor work, no dependencies beyond Foundation, WWCore,
/// WWTimeMap and WWAlignEstimate, and no route to a clock approval. Its vocabulary never presents a score as
/// a probability. (The repository-wide ForbiddenAPITests also scan every module recursively.)
@Suite("Segment purity")
struct SegmentPurityTests {
    /// Mirrors EstimatorPurityTests.forbidden (WWAlignEstimateTests/PurityTests.swift).
    static let forbidden = [
        "Data(contentsOf", "FileHandle", "InputStream", "fopen(", "open(", "read(", "mmap",
        ".write(to", "write(", "moveItem", "removeItem", "trashItem", "copyItem", "replaceItem", "linkItem",
        "setAttributes", "setResourceValue", "createFile", "createDirectory", "evictUbiquitousItem",
        "startDownloadingUbiquitousItem", "NSFileCoordinator", "AVAsset", "AVAudioFile", "AudioFileOpen",
        "ExtAudioFile", "QLThumbnail", "QuickLook", "CryptoKit", "SHA256", "CC_SHA", "Insecure.",
        "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues(",
        "URL(", "Date(", "DispatchQueue", "Task {", "Task.detached", "@MainActor", "Accelerate", "vDSP",
        "contentsOf", "contentsOfFile", "URLSession", "NSData", "Process(", "Bundle",
    ]

    static let approvalSurface = ["clockApproved", "ClockApproval", "ClockGateMeasurements", "IndependentClockReference", "Decoder", "Decodable", "Codable"]

    static let vocabulary = ["probab", "confiden", "likelihood", "percent", "certain", "chance"]

    static let allowedImports = ["import Foundation", "import WWCore", "import WWTimeMap", "import WWAlignEstimate"]

    static let moduleFiles: Set = ["Inputs.swift", "Results.swift", "Segmenter.swift"]

    /// Strips comments, keeping code AND string literals (cause and error text is user-facing).
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

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWAlignSegment")
    }

    @Test func scannerDetectsViolations() {
        #expect(Self.violations(in: "let d = try Data(contentsOf: url)", fileName: "X.swift") == ["X.swift: Data(contentsOf", "X.swift: contentsOf"])
        #expect(Self.violations(in: "let h = FileHandle(forReadingAtPath: p)", fileName: "X.swift") == ["X.swift: FileHandle"])
        #expect(Self.violations(in: "Task { await work() }", fileName: "X.swift") == ["X.swift: Task {"])
        #expect(Self.violations(in: "@MainActor func f() {}", fileName: "X.swift") == ["X.swift: @MainActor"])
        #expect(Self.violations(in: "let now = Date()", fileName: "X.swift") == ["X.swift: Date("])
        #expect(Self.violations(in: "import AVFoundation", fileName: "X.swift") == ["X.swift: import AVFoundation"])
        #expect(Self.violations(in: "import WWDecode", fileName: "X.swift") == ["X.swift: import WWDecode"])
        #expect(Self.violations(in: "import WWAlignEstimate", fileName: "X.swift").isEmpty)
        #expect(Self.violations(in: "return .clockApproved(x)", fileName: "X.swift") == ["X.swift: clockApproved"])
        #expect(Self.violations(in: "let m = try JSONDecoder().decode(MapProvenance.self, from: d)", fileName: "X.swift") == ["X.swift: Decoder"])
        #expect(Self.violations(in: "let detail = \"split likelihood\"", fileName: "X.swift") == ["X.swift: likelihood"])
        #expect(Self.violations(in: "// clockApproved and probability in a comment\nlet a = 1 // FileHandle", fileName: "X.swift").isEmpty)
    }

    /// Public callers can only run the frozen defaults: every stored parameter's setter is internal.
    @Test func parameterSettersAreNotPublic() throws {
        let source = Self.code(try String(contentsOf: Self.sourcesDirectory.appendingPathComponent("Inputs.swift"), encoding: .utf8))
        let start = try #require(source.range(of: "public struct SegmenterParameters"))
        let end = try #require(source.range(of: "public init() {}", range: start.upperBound..<source.endIndex))
        let declarations = source[start.upperBound..<end.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("var ") || $0.contains("let ") }
        #expect(declarations.count == 7)
        let publicSetters = declarations.filter { !$0.hasPrefix("public internal(set) var ") }
        #expect(publicSetters.isEmpty, "\(publicSetters)")
    }

    @Test func wwAlignSegmentIsPure() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourcesDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(Set(files.map(\.lastPathComponent)) == Self.moduleFiles)
        var violations: [String] = []
        for file in files {
            violations += Self.violations(in: try String(contentsOf: file, encoding: .utf8), fileName: file.lastPathComponent)
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}
