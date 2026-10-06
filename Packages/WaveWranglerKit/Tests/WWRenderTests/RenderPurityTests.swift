import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

/// WWRender is a pure renderer: no content, file, decode, clock, hashing or main-actor APIs, and no
/// dependencies beyond Foundation, WWCore and WWTimeMap. Samples arrive only through a caller-owned
/// ``RenderSampleProvider``. (ForbiddenAPITests in WWSourcesTests also scans this module for decode and
/// gateway tokens.)
@Suite("WWRender purity")
struct RenderPurityTests {
    /// Mirrors ForbiddenAPITests.forbidden (WWSourcesTests/EngineTests.swift); WWRender has no exceptions.
    static let forbidden = [
        "Data(contentsOf", "FileHandle", "InputStream", "fopen(", "open(", "read(", "mmap",
        ".write(to", "write(", "moveItem", "removeItem", "trashItem", "copyItem", "replaceItem", "linkItem",
        "setAttributes", "setResourceValue", "createFile", "createDirectory", "evictUbiquitousItem",
        "startDownloadingUbiquitousItem", "NSFileCoordinator", "AVAsset", "AVAudioFile", "AudioFileOpen",
        "ExtAudioFile", "QLThumbnail", "QuickLook", "CryptoKit", "SHA256", "CC_SHA", "Insecure.",
        "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues(",
        "URL(", "Date(", "DispatchQueue", "Task {", "Task.detached", "@MainActor", "Accelerate", "vDSP",
    ]
    static let allowedImports: Set<String> = ["import Foundation", "import WWCore", "import WWTimeMap"]

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
        let imports = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("import ") }
        found += imports.filter { !allowedImports.contains($0) }.map { "\(fileName): \($0)" }
        return found
    }

    @Test func scannerDetectsViolations() {
        #expect(Self.violations(in: "let h = try FileHandle(forReadingFrom: u)", fileName: "X.swift") == ["X.swift: FileHandle"])
        #expect(Self.violations(in: "import WWDecode", fileName: "X.swift") == ["X.swift: import WWDecode"])
        #expect(Self.violations(in: "import Accelerate", fileName: "X.swift") == ["X.swift: Accelerate", "X.swift: import Accelerate"])
        #expect(Self.violations(in: "// open( in a comment\nlet a = 1 // URL( here", fileName: "X.swift").isEmpty)
    }

    @Test func wwRenderIsPure() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWRender")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        var violations: [String] = []
        for file in files {
            violations += Self.violations(in: try String(contentsOf: file, encoding: .utf8), fileName: file.lastPathComponent)
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    /// No render input carries a gain, mix, polarity, proxy or stretch parameter: the group map is the only
    /// transform.
    @Test func renderInputsCarryNoGainMixProxyOrStretch() throws {
        let occurrenceID = SourceOccurrenceID()
        let epoch = RecordingEpochID()
        let map = try groupMap(
            epochs: [mapped(epoch, [seg(q(0), q(10), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: occurrence(occurrenceID, frames: 480, rate: 48000), spans: [span(0, 480, epoch)])]
        )
        let request = RenderRequest(groupMap: map, outputRate: rate(48000), outputFrames: 0 ..< 480, channels: channels(occurrenceID, 2), inputAssets: assets([occurrenceID]))
        let manifest = try GroupRenderer.plan(request)
        let banned = ["gain", "mix", "polarity", "invert", "proxy", "stretch", "tempo", "scale", "level", "volume"]
        func names(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label).map { $0.lowercased() } }
        var labels = names(request) + names(request.recipe) + names(request.recipe.kernel) + names(request.channels[0])
        labels += names(manifest) + names(manifest.occurrences[0])
        if case .source(let run) = manifest.occurrences[0].runs[0].content { labels += names(run) }
        let offending = labels.filter { label in banned.contains { label.contains($0) } }
        #expect(offending.isEmpty, "\(offending)")
    }
}
