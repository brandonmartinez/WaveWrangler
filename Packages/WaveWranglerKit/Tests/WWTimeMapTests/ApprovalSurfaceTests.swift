import Foundation
import Testing
@testable import WWTimeMap

/// There is no public path from acoustic evidence (or any free-standing value) to `clockApproved`.
/// Swift cannot assert "does not compile" in a test, so the public surface is checked by scanning the
/// module source; the scanner itself is tested against violating snippets.
@Suite("Clock approval API surface")
struct ApprovalSurfaceTests {
    static let guardedTypes = ["ClockApproval", "IndependentClockReference"]
    /// The only declarations allowed to construct a guarded type: the internal decoding records.
    static let constructionSites = ["DecodedClockApproval", "DecodedIndependentClockReference"]

    /// Bodies (from `{` to the matching `}`) of every `struct <name>` / `extension <name>` declaration.
    static func bodies(of name: String, in code: String) -> [(header: String, body: Range<String.Index>)] {
        guard let regex = try? Regex("(?m)^[^\\n]*\\b(struct|extension)\\s+\(name)\\b[^{]*\\{") else { return [] }
        return code.matches(of: regex).map { match in
            var depth = 0
            var index = code.index(before: match.range.upperBound)
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = code.index(after: index)
            }
            return (String(code[match.range]), match.range.lowerBound..<Swift.min(index, code.endIndex))
        }
    }

    static func violations(_ files: [(name: String, source: String)]) -> [String] {
        var found: [String] = []
        let codes = files.map { (name: $0.name, code: PurityTests.code($0.source)) }
        for (name, code) in codes {
            for type in guardedTypes {
                for (header, body) in bodies(of: type, in: code) {
                    // No public or package construction, factories or mutation on the guarded types.
                    for banned in ["public init", "package init", "public static", "package static", "public func", "package func", "public mutating", "public subscript"] where code[body].contains(banned) {
                        found.append("\(name): \(type) declares '\(banned)'")
                    }
                    // A public Decodable conformance is a public init(from:).
                    if header.contains("Codable") || header.contains("Decodable") { found.append("\(name): \(type) is Decodable") }
                }
                // No public declaration returns a guarded type.
                if let regex = try? Regex("(public|package)[^\\n]*->\\s*\(type)\\b"), code.contains(regex) {
                    found.append("\(name): public function returns \(type)")
                }
            }
            // Guarded types are constructed only inside the internal decoding records.
            let allowed = constructionSites.flatMap { site in bodies(of: site, in: code) }
            for (header, _) in allowed where header.contains("public") || header.contains("package") {
                found.append("\(name): construction site is public: \(header)")
            }
            for type in guardedTypes {
                guard let regex = try? Regex("\\b\(type)\\(") else { continue }
                for match in code.matches(of: regex) where !allowed.contains(where: { $0.body.contains(match.range.lowerBound) }) {
                    let line = code[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                    found.append("\(name):\(line): \(type) constructed outside the decoding records")
                }
            }
        }
        return found
    }

    @Test func scannerDetectsViolations() {
        let clean = """
        public struct ClockApproval: Hashable { init(x: Int) {} }
        extension ClockApproval: Encodable {}
        struct DecodedClockApproval: Decodable { let value: ClockApproval; init(from d: any Decoder) throws { value = ClockApproval(x: 1) } }
        """
        #expect(Self.violations([("X.swift", clean)]).isEmpty)
        #expect(Self.violations([("X.swift", "public struct ClockApproval { public init(x: Int) {} }")]) == ["X.swift: ClockApproval declares 'public init'"])
        #expect(Self.violations([("X.swift", "public struct IndependentClockReference {}\nextension IndependentClockReference: Codable {}")]) == ["X.swift: IndependentClockReference is Decodable"])
        #expect(Self.violations([("X.swift", "extension ClockApproval {\n  public static func make() -> Self { fatalError() }\n}")]) == ["X.swift: ClockApproval declares 'public static'"])
        #expect(Self.violations([("X.swift", "public func approve(_ p: AcousticConsistencyProposal) -> ClockApproval {\n  ClockApproval(x: 1)\n}")]) == [
            "X.swift: public function returns ClockApproval",
            "X.swift:2: ClockApproval constructed outside the decoding records",
        ])
        #expect(Self.violations([("X.swift", "public struct DecodedClockApproval: Decodable { init() { _ = ClockApproval(x: 1) } }")]).contains { $0.contains("construction site is public") })
    }

    @Test func noPublicPathConstructsAClockApproval() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWTimeMap")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let sources = try files.map { (name: $0.lastPathComponent, source: try String(contentsOf: $0, encoding: .utf8)) }
        // The scan must actually see the guarded declarations.
        let all = sources.map { PurityTests.code($0.source) }.joined(separator: "\n")
        for type in Self.guardedTypes + Self.constructionSites { #expect(!Self.bodies(of: type, in: all).isEmpty, "\(type) not found") }
        let violations = Self.violations(sources)
        #expect(violations.isEmpty, "\(violations)")
    }

    /// Acoustic proposals carry their own measurement type; nothing in a proposal is clock-gate evidence.
    @Test func acousticProposalsHoldNoClockGateMeasurements() throws {
        let measurements = try AcousticConsistencyMeasurements(windowCount: 100, overlapSpanFraction: 1, eligibleWindowFraction: 1, acousticResidualP95Milliseconds: 0, acousticResidualMaxMilliseconds: 0)
        let proposal = try AcousticConsistencyProposal(estimator: "x", evidenceScore: 1, measurements: measurements, seed: CaptureMetadataSeed(kind: .embeddedTimestamp))
        func holdsClockEvidence(_ value: Any, depth: Int = 0) -> Bool {
            if value is ClockGateMeasurements || value is ClockApproval || value is IndependentClockReference { return true }
            guard depth < 6 else { return false }
            return Mirror(reflecting: value).children.contains { holdsClockEvidence($0.value, depth: depth + 1) }
        }
        #expect(!holdsClockEvidence(proposal))
        #expect(type(of: proposal.measurements) == Optional<AcousticConsistencyMeasurements>.self)
        #expect(holdsClockEvidence(try ClockApproval(evaluator: "e", reference: IndependentClockReference(description: "anchors"), measurements: passingMeasurements())))
    }
}
