import Foundation
import Testing
import WWCore
@testable import WWTimeMap

@Suite("Coding")
struct CodingTests {
    let fx = Fixture()

    private func richTimeline() throws -> AlignedTimelineMap {
        let gates = try ClockGateMeasurements(windowCount: 7, overlapSpanFraction: 0.9, eligibleWindowFraction: 0.75, residualP95Milliseconds: 1.25, residualMaxMilliseconds: 2.5)
        let provenances: [MapProvenance] = [
            .clockApproved(try ClockApproval(evaluator: "synthetic/1", reference: IndependentClockReference(description: "anchors"), measurements: gates)),
            .acousticConsistentProposal(try AcousticConsistencyProposal(estimator: "gcc-phat/0", evidenceScore: 3.5, measurements: gates, seed: CaptureMetadataSeed(kind: .fileModificationDate, suggestedOffset: q(-7, 3), note: "seed only"))),
            .acousticConsistentProposal(try AcousticConsistencyProposal(estimator: "bare")),
            .manual(ManualCorrection(basis: .acceptedAcousticProposal, note: "accepted")),
            .externalEvidence(try ExternalClockEvidence(kind: .sharedWordClock, description: "house sync")),
        ]
        var groups = [try fx.referenceGroup()]
        for (index, provenance) in provenances.enumerated() {
            let epoch = RecordingEpochID(), next = RecordingEpochID(), unsupported = RecordingEpochID()
            let occurrence = fx.occurrence(frames: 144_000, rate: 44100)
            let a = try AffineClockSegment.rateRatio(ppm: q(Int64(index) * 37 - 50, 3))
            groups.append(try fx.otherGroup(
                epochs: [
                    mapped(epoch, [seg(q(0), q(1, 3), a, q(1, 7)), seg(q(1, 3), q(2), .one, try q(1, 7).adding(a.subtracting(.one).multiplied(by: q(1, 3))))], provenance),
                    EpochClockMap(epoch: unsupported, mapping: .unsupported(UnsupportedReason.allCases[index % UnsupportedReason.allCases.count])),
                    mapped(next, [seg(q(10), q(20), .one, q(1, 3))], provenance),
                ],
                placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 44100, epoch), span(44100, 88200, unsupported), span(100_000, 144_000, next, e: q(10))])]
            ))
        }
        return try AlignedTimelineMap(reference: fx.reference, groups: groups)
    }

    private func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    private func decodeTimeline(_ data: Data) throws -> AlignedTimelineMap { try JSONDecoder().decode(AlignedTimelineMap.self, from: data) }

    @Test func roundTripsEveryProvenanceAndState() throws {
        let map = try richTimeline()
        let encoded = try json(map)
        let decoded = try decodeTimeline(encoded)
        #expect(decoded == map)
        #expect(try json(decoded) == encoded)
        // Behaviour survives too (compiled state is rebuilt by validation, not trusted from the file).
        for group in map.groups {
            for id in group.occurrenceIDs {
                for frame: Int64 in [0, 22050, 44099, 50000, 100_000, 143_999] {
                    #expect(try decoded.alignedTime(ofFrame: frame, in: id) == map.alignedTime(ofFrame: frame, in: id))
                }
            }
        }
        let group = map.groups[1]
        #expect(try JSONDecoder().decode(GroupTimeMap.self, from: json(group)) == group)
    }

    @Test func versionIsWrittenAndCheckedFirst() throws {
        let map = try richTimeline()
        var root = try object(json(map))
        #expect(root["timeMapSchemaVersion"] as? Int == TimeMapSchema.currentVersion)
        #expect(TimeMapSchema.currentVersion == 1)
        // A newer version is refused as newer, even when the rest of the document is unreadable.
        root["timeMapSchemaVersion"] = 2
        #expect(throws: TimeMapDecodingError.unknownNewerSchemaVersion(found: 2, supported: 1)) { try decodeTimeline(data(root)) }
        #expect(throws: TimeMapDecodingError.unknownNewerSchemaVersion(found: 99, supported: 1)) { try decodeTimeline(data(["timeMapSchemaVersion": 99, "futureField": true])) }
        root["timeMapSchemaVersion"] = 0
        #expect(throws: TimeMapDecodingError.unsupportedSchemaVersion(0)) { try decodeTimeline(data(root)) }
        root["timeMapSchemaVersion"] = nil
        #expect(throws: DecodingError.self) { try decodeTimeline(data(root)) }
        // Nested group maps carry and check their own version.
        var group = try object(json(map.groups[1]))
        #expect(group["timeMapSchemaVersion"] as? Int == 1)
        group["timeMapSchemaVersion"] = 2
        #expect(throws: TimeMapDecodingError.unknownNewerSchemaVersion(found: 2, supported: 1)) { try JSONDecoder().decode(GroupTimeMap.self, from: data(group)) }
    }

    @Test func unknownKeysAreRefusedAtEveryLevel() throws {
        let map = try richTimeline()
        var root = try object(json(map))
        root["extra"] = 1
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "AlignedTimelineMap", keys: ["extra"])) { try decodeTimeline(data(root)) }

        func mutateGroup(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var root = try object(json(map))
            var groups = try #require(root["groups"] as? [[String: Any]])
            edit(&groups[1])
            root["groups"] = groups
            return try data(root)
        }
        func nested(_ path: [String], _ index: Int = 0) -> (inout [String: Any]) -> Void {
            { group in
                var epochs = group["epochs"] as! [[String: Any]]
                var epoch = epochs[index]
                if path == ["epoch"] {
                    epoch["future"] = 1
                } else if path == ["segment"] {
                    var segments = epoch["segments"] as! [[String: Any]]
                    segments[0]["stretch"] = "1/1"
                    epoch["segments"] = segments
                } else if path == ["provenance"] {
                    var provenance = epoch["provenance"] as! [String: Any]
                    provenance["manual"] = ["basis": "anchors", "note": ""]
                    epoch["provenance"] = provenance
                } else if path == ["clockApproval"] {
                    var provenance = epoch["provenance"] as! [String: Any]
                    var approval = provenance["clockApproval"] as! [String: Any]
                    approval["metadataSeed"] = ["kind": "fileCreationDate", "note": ""]
                    provenance["clockApproval"] = approval
                    epoch["provenance"] = provenance
                }
                epochs[index] = epoch
                group["epochs"] = epochs
            }
        }
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "EpochClockMap", keys: ["future"])) { try decodeTimeline(mutateGroup(nested(["epoch"]))) }
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "AffineClockSegment", keys: ["stretch"])) { try decodeTimeline(mutateGroup(nested(["segment"]))) }
        // groups[1] is clock-approved: a second payload is refused, and metadata cannot ride along.
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "MapProvenance.clockApproved", keys: ["manual"])) { try decodeTimeline(mutateGroup(nested(["provenance"]))) }
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "ClockApproval", keys: ["metadataSeed"])) { try decodeTimeline(mutateGroup(nested(["clockApproval"]))) }
        let spanExtra = try mutateGroup { group in
            var placements = group["placements"] as! [[String: Any]]
            var spans = placements[0]["spans"] as! [[String: Any]]
            spans[0]["bridge"] = true
            placements[0]["spans"] = spans
            group["placements"] = placements
        }
        #expect(throws: TimeMapDecodingError.unknownKeys(type: "EpochSpan", keys: ["bridge"])) { try decodeTimeline(spanExtra) }
        let unknownKind = try mutateGroup { group in
            var epochs = group["epochs"] as! [[String: Any]]
            epochs[0]["provenance"] = ["kind": "metadataClock"]
            group["epochs"] = epochs
        }
        #expect(throws: TimeMapDecodingError.unknownKind(type: "MapProvenance", kind: "metadataClock")) { try decodeTimeline(unknownKind) }
        let unknownState = try mutateGroup { group in
            var epochs = group["epochs"] as! [[String: Any]]
            epochs[0]["state"] = "bridged"
            group["epochs"] = epochs
        }
        #expect(throws: TimeMapDecodingError.unknownKind(type: "EpochClockMap", kind: "bridged")) { try decodeTimeline(unknownState) }
    }

    @Test func invalidContentIsRefusedOnDecode() throws {
        let map = try richTimeline()
        func mutateFirstSegment(_ key: String, _ value: Any) throws -> Data {
            var root = try object(json(map))
            var groups = root["groups"] as! [[String: Any]]
            var epochs = groups[1]["epochs"] as! [[String: Any]]
            var segments = epochs[0]["segments"] as! [[String: Any]]
            segments[1][key] = value
            epochs[0]["segments"] = segments
            groups[1]["epochs"] = epochs
            root["groups"] = groups
            return try data(root)
        }
        // A discontinuity smuggled in through the file is refused by validation.
        #expect(throws: TimeMapError.self) { try decodeTimeline(mutateFirstSegment("alignedOffset", "1/2")) }
        #expect(throws: TimeMapError.nonPositiveRateRatio) { try decodeTimeline(mutateFirstSegment("rateRatio", "-1/1")) }
        // Rationals must be canonical strings; JSON numbers and non-canonical forms are refused.
        #expect(throws: TimeMapDecodingError.malformedRational("2/4")) { try decodeTimeline(mutateFirstSegment("rateRatio", "2/4")) }
        #expect(throws: TimeMapDecodingError.malformedRational("1/-2")) { try decodeTimeline(mutateFirstSegment("rateRatio", "1/-2")) }
        #expect(throws: TimeMapDecodingError.malformedRational("1")) { try decodeTimeline(mutateFirstSegment("rateRatio", "1")) }
        #expect(throws: TimeMapDecodingError.malformedRational("1/0")) { try decodeTimeline(mutateFirstSegment("rateRatio", "1/0")) }
        #expect(throws: DecodingError.self) { try decodeTimeline(mutateFirstSegment("rateRatio", 1.0001)) }
        #expect(throws: DecodingError.self) { try decodeTimeline(mutateFirstSegment("rateRatio", 1)) }
        // A failing clock approval cannot be decoded.
        var root = try object(json(map))
        var groups = root["groups"] as! [[String: Any]]
        var epochs = groups[1]["epochs"] as! [[String: Any]]
        var provenance = epochs[0]["provenance"] as! [String: Any]
        var approval = provenance["clockApproval"] as! [String: Any]
        var measurements = approval["measurements"] as! [String: Any]
        measurements["windowCount"] = 4
        approval["measurements"] = measurements
        provenance["clockApproval"] = approval
        epochs[0]["provenance"] = provenance
        groups[1]["epochs"] = epochs
        root["groups"] = groups
        #expect(throws: TimeMapError.clockApprovalGateNotMet(["windowCount"])) { try decodeTimeline(data(root)) }
        // Invalid rate / frame count.
        #expect(throws: TimeMapError.invalidNominalRate(0)) { try JSONDecoder().decode(NominalRate.self, from: Data("0".utf8)) }
    }

    @Test func encodedFormHasNoProbabilityVocabularyAndExactStrings() throws {
        let text = try #require(String(data: try json(try richTimeline()), encoding: .utf8)).lowercased()
        for banned in ["probability", "likelihood", "confidence", "percent", "stretch"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        #expect(text.contains("\"rateratio\":\""))
    }
}
