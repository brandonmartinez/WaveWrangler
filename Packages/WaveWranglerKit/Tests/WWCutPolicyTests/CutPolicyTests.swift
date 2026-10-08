import Testing
@testable import WWCutPolicy

private struct FixtureMapper: CutFootprintMapping {
    let proof: CutFootprint
    func footprint(for request: CutRequest, primary: SourceOccurrence) throws -> CutFootprint {
        proof
    }
}

@Suite("Conservative protected-cut policy")
struct CutPolicyTests {
    static let primary = SourceOccurrence(source: "primary", channel: 0, occurrence: "p1", epoch: "e1")
    static let backup = SourceOccurrence(source: "backup", channel: 1, occurrence: "b1", epoch: "e1")
    static let other = SourceOccurrence(source: "other", channel: 0, occurrence: "o1", epoch: "e1")

    static func span(_ start: Int64, _ end: Int64) -> FrameSpan {
        try! FrameSpan(start, end)
    }

    static let lanes = [
        LaneRevision(id: "primary", kind: .selectedPrimary, origin: primary,
                     backingRevision: "a1", mapRevision: "m1", protectionRevision: "p1"),
        LaneRevision(id: "backup", kind: .backup, origin: backup,
                     backingRevision: "a2", mapRevision: "m1", protectionRevision: "p2"),
        LaneRevision(id: "other", kind: .otherSpeaker, origin: other,
                     backingRevision: "a3", mapRevision: "m1", protectionRevision: "p3"),
        LaneRevision(id: "silence", kind: .intentionalSilence, origin: nil,
                     backingRevision: "s1", mapRevision: "m1", protectionRevision: "p4"),
    ]

    static func key(source: String = "s1", model: String = "local1",
                    primary: SourceOccurrence = primary, correction: String = "c1",
                    authorization: PrimaryAuthorization = .authorizedSelectedPrimary,
                    map: String = "m1", asset: String = "a1", format: String = "f1",
                    protection: String = "p1", transcript: String = "t1",
                    recipe: String = "r1", cuts: String = "cuts1",
                    manifest: String = "episode-lanes-1") -> EvidenceKey {
        EvidenceKey(primary: primary, primaryAuthorization: authorization,
                    sourceRevision: source, modelRevision: model,
                    transcriptRevision: transcript, correctionRevision: correction,
                    alignmentRevision: map, assetRevision: asset, formatRevision: format,
                    protectionRevision: protection, outputRecipeRevision: recipe,
                    otherCutsRevision: cuts, laneManifestRevision: manifest)
    }

    static func state(key: EvidenceKey = key(), lanes: [LaneRevision] = lanes,
                      manifest: String = "episode-lanes-1") -> VerifiedEpisodeState {
        VerifiedEpisodeState(key: key, manifest: EpisodeLaneManifest(revision: manifest, lanes: lanes))
    }

    static func proposal(timing: WordTiming = .supported(start: 100, end: 110),
                         sourceBase: Int64 = 100, key: EvidenceKey = key(),
                         context: CandidateContext = .contextualFiller) -> CutProposal {
        CutProposal(id: "proposal-1", key: key,
                    words: [CandidateWord(tokenID: "word-1", timing: timing)],
                    context: context, request: CutRequest(sourceFrames: span(sourceBase, sourceBase + 10)))
    }

    static func review(_ candidate: CutProposal, request: CutRequest? = nil,
                       actionID: String = "person-action-1",
                       manifest: String = "episode-lanes-1") -> HumanReviewAction {
        HumanReviewAction(actionID: actionID, proposalID: candidate.id,
                          request: request ?? candidate.request, key: candidate.key,
                          manifestRevision: manifest)
    }

    static func proof(key: EvidenceKey = key(), manifest: String = "episode-lanes-1",
                      primaryProtection: ProtectionProof? = nil,
                      backupProtection: ProtectionProof? = nil,
                      otherProtection: ProtectionProof? = nil,
                      mode: CutMode = .shorten, fade: [FrameSpan] = [],
                      fadeLength: Int64 = 0, backupBacked: Bool = true,
                      backupOrigin: SourceOccurrence = backup, boundary: BoundarySupport = .supported,
                      endpointError: Int64 = 1, sourceBase: Int64 = 100,
                      gridBase: Int64 = 200, coverageEnd: Int64 = 6_000,
                      laneIDs: [String] = ["primary", "backup", "other", "silence"]) -> CutFootprint {
        let fadeFootprint = FadeFootprint(fadeOut: fadeLength > 0 ? fade.first : nil,
                                          mergedFinal: fade)
        let all: [LaneFootprint] = [
            .audio(id: "primary", origin: primary, coverage: span(1, coverageEnd),
                   removal: span(sourceBase, sourceBase + 10), fades: fadeFootprint,
                   protection: primaryProtection ?? .verifiedPrimary(primary, revision: "p1", protected: []),
                   backed: true, boundary: boundary, fadeOutOutputFrames: fadeLength,
                   fadeInOutputFrames: 0, endpointErrorOutputFrames: endpointError),
            .audio(id: "backup", origin: backupOrigin, coverage: span(1, coverageEnd),
                   removal: span(sourceBase + 20, sourceBase + 30), fades: fadeFootprint,
                   protection: backupProtection ?? .verifiedIndependentLane(backup, revision: "p2", protected: []),
                   backed: backupBacked, boundary: .supported, fadeOutOutputFrames: fadeLength,
                   fadeInOutputFrames: 0, endpointErrorOutputFrames: endpointError),
            .audio(id: "other", origin: other, coverage: span(1, coverageEnd),
                   removal: span(sourceBase + 40, sourceBase + 50), fades: fadeFootprint,
                   protection: otherProtection ?? .verifiedIndependentLane(other, revision: "p3", protected: []),
                   backed: true, boundary: .supported, fadeOutOutputFrames: fadeLength,
                   fadeInOutputFrames: 0, endpointErrorOutputFrames: endpointError),
            .intentionalSilence(id: "silence", gridCoverage: span(1, coverageEnd)),
        ]
        return CutFootprint(key: key, manifestRevision: manifest,
                            grid: span(gridBase, gridBase + 10), outputRate: 48_000,
                            effect: mode == .shorten ? .shorten(removedOutputFrames: 10) :
                                .lift(reservedOutputFrames: 10),
                            lanes: laneIDs.compactMap { id in all.first(where: { $0.id == id }) })
    }

    static func admit(_ candidate: CutProposal = proposal(), request: CutRequest? = nil,
                      state: VerifiedEpisodeState? = state(), review: HumanReviewAction? = nil,
                      proof: CutFootprint = proof()) throws -> ApprovedCut {
        let request = request ?? candidate.request
        return try CutPolicy.admit(candidate, request: request, current: state,
                                   review: review ?? Self.review(candidate, request: request),
                                   mapping: FixtureMapper(proof: proof))
    }

    @Test("Proposals are inert; transcript classes and unsupported words do not prove safety")
    func pendingIsInert() {
        #expect(ReviewJournal(proposal: Self.proposal()).current.decision == .pending)
        #expect(ReviewJournal(proposal: Self.proposal()).current.decision.activeCut == nil)
        for context in [CandidateContext.meaningful, .overlap, .uncertain, .transcriptEmpty] {
            #expect(ReviewJournal(proposal: Self.proposal(context: context)).current.decision ==
                    .blocked(.notContextualFiller))
        }
        for timing in [WordTiming.absent, .unsupported, .hallucinated] {
            #expect(ReviewJournal(proposal: Self.proposal(timing: timing)).current.decision ==
                    .blocked(.unsupportedWord))
        }
    }

    @Test("120 distinct placements across Primary, Backup, other speaker and an omitted lane refuse both modes")
    func protectionMatrix() {
        for i in 0..<120 {
            let base = Int64(100 + i * 13)
            let caseIndex = i % 4
            let lane = ["primary", "backup", "other", "other"][caseIndex]
            let protectedFrame = base + Int64([0, 29, 49, 49][caseIndex])
            let protected = Self.span(protectedFrame, protectedFrame + 1)
            for mode in [CutMode.shorten, .lift] {
                let proof = Self.proof(
                    primaryProtection: caseIndex == 0
                        ? .verifiedPrimary(Self.primary, revision: "p1", protected: [protected]) : nil,
                    backupProtection: caseIndex == 1
                        ? .verifiedIndependentLane(Self.backup, revision: "p2", protected: [protected]) : nil,
                    otherProtection: caseIndex == 2
                        ? .verifiedIndependentLane(Self.other, revision: "p3", protected: [protected]) : nil,
                    mode: mode, sourceBase: base, gridBase: base + 100,
                    laneIDs: caseIndex == 3 ? ["primary", "backup", "silence"] :
                        ["primary", "backup", "other", "silence"])
                let candidate = Self.proposal(timing: .supported(start: base, end: base + 10),
                                               sourceBase: base)
                let request = CutRequest(sourceFrames: candidate.request.sourceFrames, mode: mode)
                if caseIndex == 3 {
                    #expect(throws: CutRefusal.incompleteLanes) {
                        try Self.admit(candidate, request: request, proof: proof)
                    }
                } else {
                    #expect(throws: CutRefusal.protectedFrame(lane)) {
                        try Self.admit(candidate, request: request, proof: proof)
                    }
                }
            }
        }
    }

    @Test("Only an authoritative exact episode manifest admits a cut")
    func manifestAndAuthority() throws {
        let candidate = Self.proposal()
        #expect(throws: CutRefusal.missingLaneAuthority) {
            try CutPolicy.admit(candidate, request: candidate.request, current: nil,
                                review: Self.review(candidate), mapping: FixtureMapper(proof: Self.proof()))
        }
        let admitted = try Self.admit()
        #expect(admitted.footprint.grid == Self.span(200, 210))
        for lanes in [
            Array(Self.lanes.dropLast()), Self.lanes + [Self.lanes[1]],
            Self.lanes + [LaneRevision(id: "extra", kind: .backup, origin: Self.backup,
                                       backingRevision: "a4", mapRevision: "m1", protectionRevision: "p4")],
            Self.lanes + [LaneRevision(id: "second-primary", kind: .selectedPrimary, origin: Self.other,
                                       backingRevision: "a3", mapRevision: "m1", protectionRevision: "p3")],
        ] {
            #expect(throws: CutRefusal.incompleteLanes) {
                try Self.admit(state: Self.state(lanes: lanes))
            }
        }
        #expect(throws: CutRefusal.incompleteLanes) {
            try Self.admit(proof: Self.proof(laneIDs: ["primary", "backup", "backup", "silence"]))
        }
        #expect(throws: CutRefusal.staleEvidence) {
            try Self.admit(state: Self.state(manifest: "episode-lanes-2"))
        }
        #expect(throws: CutRefusal.staleEvidence) {
            try Self.admit(proof: Self.proof(manifest: "episode-lanes-2"))
        }
    }

    @Test("Person-initiated review is mandatory and bound to the exact action and state")
    func humanReview() throws {
        let candidate = Self.proposal()
        #expect(throws: CutRefusal.missingHumanReview) {
            try CutPolicy.admit(candidate, request: candidate.request, current: Self.state(),
                                review: nil, mapping: FixtureMapper(proof: Self.proof()))
        }
        for review in [
            Self.review(candidate, actionID: ""),
            HumanReviewAction(actionID: "a", proposalID: "another", request: candidate.request,
                              key: candidate.key, manifestRevision: "episode-lanes-1"),
            Self.review(candidate, manifest: "episode-lanes-2"),
            Self.review(candidate, request: CutRequest(sourceFrames: Self.span(101, 109))),
        ] {
            #expect(throws: CutRefusal.missingHumanReview) {
                try Self.admit(candidate, review: review)
            }
        }
        let accepted = try Self.admit()
        #expect(accepted.review.actionID == "person-action-1")
        var journal = ReviewJournal(proposal: candidate)
        #expect(throws: CutRefusal.missingHumanReview) {
            try journal.accept(current: Self.state(), review: nil,
                               mapping: FixtureMapper(proof: Self.proof()))
        }
        #expect(journal.transitions.isEmpty)
        try journal.accept(current: Self.state(), review: Self.review(candidate),
                           mapping: FixtureMapper(proof: Self.proof()))
        #expect(journal.current.decision.activeCut?.review == Self.review(candidate))
    }

    @Test("Independently reviewed, identity-bound protection refuses unknown and mismatched evidence")
    func provenanceAndFades() {
        for evidence in [
            ProtectionProof.unknown, .overlap, .backupWithoutIndependentProof,
            .unsupportedBoundary, .verifiedPrimary(Self.backup, revision: "p2", protected: []),
            .verifiedIndependentLane(Self.backup, revision: "stale", protected: []),
        ] {
            #expect(throws: CutRefusal.uninspectableLane("backup")) {
                try Self.admit(proof: Self.proof(backupProtection: evidence))
            }
        }
        for boundary in [BoundarySupport.unsupported, .ambiguousInverse, .crossesOccurrenceOrEpoch] {
            #expect(throws: CutRefusal.uninspectableLane("primary")) {
                try Self.admit(proof: Self.proof(boundary: boundary))
            }
        }
        #expect(throws: CutRefusal.uninspectableLane("backup")) {
            try Self.admit(proof: Self.proof(backupBacked: false))
        }
        #expect(throws: CutRefusal.uninspectableLane("backup")) {
            try Self.admit(proof: Self.proof(backupOrigin: Self.primary))
        }
        #expect(throws: CutRefusal.uninspectableLane("primary")) {
            try Self.admit(proof: Self.proof(primaryProtection:
                .verifiedIndependentLane(Self.primary, revision: "p1", protected: [])))
        }
        #expect(throws: CutRefusal.uninspectableLane("primary")) {
            try Self.admit(proof: Self.proof(endpointError: 2))
        }
        let request = CutRequest(sourceFrames: Self.span(100, 110), fadeOutFrames: 2)
        let lastFrame = Self.span(499, 500)
        #expect(throws: CutRefusal.protectedFrame("backup")) {
            try Self.admit(request: request,
                           proof: Self.proof(
                            backupProtection: .verifiedIndependentLane(Self.backup, revision: "p2",
                                                                        protected: [lastFrame]),
                            fade: [Self.span(498, 500)], fadeLength: 2))
        }
        #expect(throws: CutRefusal.unsupportedFade("primary")) {
            try Self.admit(request: request)
        }
    }

    @Test("Every dependency and reactivation proof must be current")
    func staleKeys() throws {
        let changed = [
            Self.key(source: "s2"), Self.key(model: "local2"),
            Self.key(primary: Self.backup), Self.key(correction: "c2"),
            Self.key(map: "m2"), Self.key(asset: "a2"), Self.key(format: "f2"),
            Self.key(protection: "p2"), Self.key(transcript: "t2"),
            Self.key(recipe: "r2"), Self.key(cuts: "cuts2"),
            Self.key(manifest: "episode-lanes-2"),
        ]
        for key in changed {
            #expect(throws: CutRefusal.staleEvidence) {
                try Self.admit(state: Self.state(key: key))
            }
        }
        let candidate = Self.proposal()
        var journal = ReviewJournal(proposal: candidate)
        let mapping = FixtureMapper(proof: Self.proof())
        try journal.accept(current: Self.state(), review: Self.review(candidate), mapping: mapping)
        try journal.restore()
        for key in changed {
            #expect(throws: CutRefusal.staleEvidence) {
                try journal.undo(current: Self.state(key: key), mapping: mapping)
            }
            #expect(journal.cursor == 2)
            #expect(journal.transitions.count == 2)
            #expect(journal.current.decision.activeCut == nil)
        }
        let unauthorized = Self.key(authorization: .notAuthorized)
        let unconsented = Self.proposal(key: unauthorized)
        #expect(throws: CutRefusal.unauthorizedPrimary) {
            try Self.admit(unconsented, state: Self.state(key: unauthorized),
                           proof: Self.proof(key: unauthorized))
        }
        let missing = Self.key(asset: "")
        let missingProposal = Self.proposal(key: missing)
        #expect(throws: CutRefusal.invalidIdentity) {
            try Self.admit(missingProposal, state: Self.state(key: missing),
                           proof: Self.proof(key: missing))
        }
    }

    @Test("Undo and redo append events; fork after undo retains the old audit branch")
    func history() throws {
        let candidate = Self.proposal()
        let mapping = FixtureMapper(proof: Self.proof())
        var journal = ReviewJournal(proposal: candidate)
        let initial = journal.current
        try journal.accept(current: Self.state(), review: Self.review(candidate), mapping: mapping)
        let accepted = journal.current
        try journal.restore()
        let restored = journal.current
        #expect(restored.decision.activeCut == nil)
        try journal.undo(current: Self.state(), mapping: mapping)
        #expect(journal.current == accepted)
        try journal.undo(current: Self.state(), mapping: mapping)
        #expect(journal.current == initial)
        try journal.redo(current: Self.state(), mapping: mapping)
        #expect(journal.current == accepted)
        try journal.redo(current: Self.state(), mapping: mapping)
        #expect(journal.current == restored)
        #expect(journal.transitions.map(\.actionName) == [
            "Accept proposal-1", "Restore proposal-1",
            "Undo Restore proposal-1", "Undo Accept proposal-1",
            "Redo Accept proposal-1", "Redo Restore proposal-1",
        ])
        try journal.undo(current: Self.state(), mapping: mapping)
        try journal.restore()
        #expect(journal.transitions.count == 8)
        #expect(journal.transitions[1].after == restored)
        #expect(journal.transitions[7].before == accepted)
        #expect(journal.transitions[7].parentHead == 6)
        #expect(journal.transitions[7].branchID == 7)
        #expect(journal.head == 7)
        #expect(throws: CutRefusal.invalidTransition) {
            try journal.redo(current: Self.state(), mapping: mapping)
        }
        try journal.undo(current: Self.state(), mapping: mapping)
        try journal.undo(current: Self.state(), mapping: mapping)
        try journal.abstain()
        #expect(journal.transitions[0].after.decision.activeCut != nil)
        #expect(journal.transitions[1].after == restored)
        #expect(journal.transitions.last?.branchID == 10)
    }

    @Test("A different accepted edit after Undo retains the prior accepted event and a new branch")
    func acceptedFork() throws {
        let candidate = Self.proposal()
        var journal = ReviewJournal(proposal: candidate)
        let shorten = FixtureMapper(proof: Self.proof())
        try journal.accept(current: Self.state(), review: Self.review(candidate), mapping: shorten)
        let original = journal.current
        try journal.undo(current: Self.state(), mapping: shorten)
        let liftRequest = CutRequest(sourceFrames: candidate.request.sourceFrames, mode: .lift)
        try journal.adjust(liftRequest)
        let lift = FixtureMapper(proof: Self.proof(mode: .lift))
        #expect(throws: CutRefusal.missingHumanReview) {
            try journal.accept(current: Self.state(),
                               review: Self.review(candidate, request: liftRequest),
                               mapping: lift)
        }
        try journal.accept(current: Self.state(),
                           review: Self.review(candidate, request: liftRequest,
                                               actionID: "person-action-2"), mapping: lift)
        #expect(journal.transitions.count == 4)
        #expect(journal.transitions[0].after == original)
        #expect(journal.transitions[2].branchID == 2)
        #expect(journal.transitions[3].branchID == 2)
        #expect(journal.transitions[3].after.decision.activeCut?.request.mode == .lift)
        #expect(journal.head == 3)
    }

    @Test("Lift and Shorten require exact shared output-grid duration")
    func liftDuration() throws {
        let candidate = Self.proposal()
        let request = CutRequest(sourceFrames: candidate.request.sourceFrames, mode: .lift)
        let approved = try Self.admit(candidate, request: request, proof: Self.proof(mode: .lift))
        #expect(approved.footprint.effect == .lift(reservedOutputFrames: 10))
        #expect(approved.footprint.grid == Self.span(200, 210))
        #expect(throws: CutRefusal.invalidGrid) {
            try Self.admit(candidate, request: request)
        }
        let shortGap = CutFootprint(key: Self.key(), manifestRevision: "episode-lanes-1",
                                    grid: Self.span(200, 210), outputRate: 48_000,
                                    effect: .lift(reservedOutputFrames: 9),
                                    lanes: Self.proof(mode: .lift).lanes)
        #expect(throws: CutRefusal.invalidGrid) {
            try Self.admit(candidate, request: request, proof: shortGap)
        }
    }

    @Test("Reject, adjust and abstain preserve named decisions and never accept automatically")
    func reviewDecisions() throws {
        var journal = ReviewJournal(proposal: Self.proposal())
        try journal.adjust(CutRequest(sourceFrames: Self.span(101, 109)))
        #expect(journal.current.decision == .adjusted)
        #expect(journal.current.decision.activeCut == nil)
        try journal.reject()
        try journal.undo(current: nil, mapping: FixtureMapper(proof: Self.proof()))
        #expect(journal.current.decision == .adjusted)
        try journal.abstain()
        #expect(journal.current.decision == .abstained)
        #expect(journal.transitions.map(\.actionName) == [
            "Adjust proposal-1", "Reject proposal-1",
            "Undo Reject proposal-1", "Abstain proposal-1",
        ])
    }

    @Test("Unsupported timing, missing silent coverage and uninspectable lanes refuse")
    func unsupported() {
        let candidate = Self.proposal(timing: .hallucinated)
        #expect(throws: CutRefusal.unsupportedWord) {
            try Self.admit(candidate)
        }
        let missingSilence = CutFootprint(key: Self.key(), manifestRevision: "episode-lanes-1",
                                          grid: Self.span(200, 210), outputRate: 48_000,
                                          effect: .shorten(removedOutputFrames: 10),
                                          lanes: Self.proof(laneIDs: ["primary", "backup", "other"]).lanes +
                                            [.intentionalSilence(id: "silence",
                                                                 gridCoverage: Self.span(1, 199))])
        #expect(throws: CutRefusal.uninspectableLane("silence")) {
            try Self.admit(proof: missingSilence)
        }
        let unsupported = CutFootprint(key: Self.key(), manifestRevision: "episode-lanes-1",
                                        grid: Self.span(200, 210), outputRate: 48_000,
                                        effect: .shorten(removedOutputFrames: 10),
                                        lanes: [.unsupported(id: "primary")] +
                                            Self.proof(laneIDs: ["backup", "other", "silence"]).lanes)
        #expect(throws: CutRefusal.uninspectableLane("primary")) {
            try Self.admit(proof: unsupported)
        }
    }
}
