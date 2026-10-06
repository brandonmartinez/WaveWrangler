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

    /// Randomness and hash-order dependence (matched case-insensitively). The single exception is minting a fresh
    /// epoch identifier with `RecordingEpochID()` (a UUID), at exactly `epochMintSites` places; identifiers never
    /// feed a numeric result, so every position, residual and decision is deterministic.
    static let nondeterminism = ["random", "uuid", "shuffle", "hasher", "hashvalue", "arc4", "seed"]
    static let epochMint = "RecordingEpochID()"
    /// Segmenter.swift: the epoch of each extra region a split creates, and the scratch epoch of an estimator track.
    static let epochMintSites = 2

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
        found += nondeterminism.filter { lower.contains($0) }.map { "\(fileName): \($0)" }
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
        #expect(Self.violations(in: "let x = Double.random(in: 0...1)", fileName: "X.swift") == ["X.swift: random"])
        #expect(Self.violations(in: "var g = SystemRandomNumberGenerator()", fileName: "X.swift") == ["X.swift: random"])
        #expect(Self.violations(in: "let id = UUID()", fileName: "X.swift") == ["X.swift: uuid"])
        #expect(Self.violations(in: "items.shuffled()", fileName: "X.swift") == ["X.swift: shuffle"])
        #expect(Self.violations(in: "var h = Hasher()", fileName: "X.swift") == ["X.swift: hasher"])
        #expect(Self.violations(in: "let e = RecordingEpochID()", fileName: "X.swift").isEmpty)
        #expect(Self.epochMints(in: "let e = RecordingEpochID()\n// RecordingEpochID()\nlet f = RecordingEpochID()") == 2)
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

    static func epochMints(in source: String) -> Int {
        code(source).components(separatedBy: epochMint).count - 1
    }

    @Test func wwAlignSegmentIsPure() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourcesDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(Set(files.map(\.lastPathComponent)) == Self.moduleFiles)
        var violations: [String] = []
        var mints = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            violations += Self.violations(in: source, fileName: file.lastPathComponent)
            mints += Self.epochMints(in: source)
        }
        #expect(violations.isEmpty, "\(violations)")
        #expect(mints == Self.epochMintSites, "fresh epoch identifiers are minted at \(mints) sites, not \(Self.epochMintSites)")
    }
}
