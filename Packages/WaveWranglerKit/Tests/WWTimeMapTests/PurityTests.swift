import Foundation
import Testing

/// WWTimeMap is pure coordinate arithmetic: no content, file, decode or mutation APIs, no Double in the
/// map arithmetic, and no dependencies beyond Foundation and WWCore.
@Suite("Module purity")
struct PurityTests {
    /// Mirrors ForbiddenAPITests.forbidden (WWSourcesTests/EngineTests.swift); WWTimeMap has no exceptions.
    static let forbidden = [
        "Data(contentsOf", "FileHandle", "InputStream", "fopen(", "open(", "read(", "mmap",
        ".write(to", "write(", "moveItem", "removeItem", "trashItem", "copyItem", "replaceItem", "linkItem",
        "setAttributes", "setResourceValue", "createFile", "createDirectory", "evictUbiquitousItem",
        "startDownloadingUbiquitousItem", "NSFileCoordinator", "AVAsset", "AVAudioFile", "AudioFileOpen",
        "ExtAudioFile", "QLThumbnail", "QuickLook", "CryptoKit", "SHA256", "CC_SHA", "Insecure.",
        "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues(",
        "URL(", "Date(", "DispatchQueue", "Task {", "Task.detached", "@MainActor",
    ]

    /// Map arithmetic files: no floating point at all (Double is allowed only for measurement values and
    /// the display-only `approximateDouble`).
    static let exactFiles: Set<String> = ["GroupTimeMap.swift", "AlignedTimelineMap.swift", "ClockConventions.swift", "TimeMapCoding.swift"]

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
        var found = forbidden.filter { code.contains($0) }.map { "\(fileName): \($0)" }
        if exactFiles.contains(fileName) {
            found += ["Double", "Float", "CGFloat", "TimeInterval", "CMTime"].filter { code.contains($0) }.map { "\(fileName): \($0)" }
        }
        let imports = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("import ") }
        found += imports.filter { !["import Foundation", "import WWCore"].contains($0) }.map { "\(fileName): \($0)" }
        return found
    }

    @Test func scannerDetectsViolations() {
        #expect(Self.violations(in: "let d = try Data(contentsOf: url)", fileName: "X.swift") == ["X.swift: Data(contentsOf"])
        #expect(Self.violations(in: "import AVFoundation", fileName: "X.swift") == ["X.swift: import AVFoundation"])
        #expect(Self.violations(in: "let x: Double = 1", fileName: "GroupTimeMap.swift") == ["GroupTimeMap.swift: Double"])
        #expect(Self.violations(in: "// FileHandle in a comment\nlet a = 1 // Double here", fileName: "GroupTimeMap.swift").isEmpty)
    }

    @Test func wwTimeMapIsPure() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWTimeMap")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 7)
        #expect(Self.exactFiles.isSubset(of: Set(files.map(\.lastPathComponent))))
        var violations: [String] = []
        for file in files {
            violations += Self.violations(in: try String(contentsOf: file, encoding: .utf8), fileName: file.lastPathComponent)
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}
