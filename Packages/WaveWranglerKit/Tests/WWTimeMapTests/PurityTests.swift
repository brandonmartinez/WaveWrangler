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
        "contentsOf", "contentsOfFile", "URLSession", "NSData", "Process(", "Bundle",
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
        #expect(Self.violations(in: "let d = try Data(contentsOf: url)", fileName: "X.swift") == ["X.swift: Data(contentsOf", "X.swift: contentsOf"])
        #expect(Self.violations(in: "let s = try String(contentsOf: url, encoding: .utf8)", fileName: "X.swift") == ["X.swift: contentsOf"])
        #expect(Self.violations(in: "let s = try String(contentsOfFile: path)", fileName: "X.swift") == ["X.swift: contentsOf", "X.swift: contentsOfFile"])
        #expect(Self.violations(in: "let t = URLSession.shared.dataTask(with: request)", fileName: "X.swift") == ["X.swift: URLSession"])
        #expect(Self.violations(in: "let d = NSData(bytes: p, length: n)", fileName: "X.swift") == ["X.swift: NSData"])
        #expect(Self.violations(in: "let p = Process()", fileName: "X.swift") == ["X.swift: Process("])
        #expect(Self.violations(in: "let b = Bundle.main", fileName: "X.swift") == ["X.swift: Bundle"])
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
