import Testing
import WWCutPolicy

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

    static func span(_ start: Int64, _ end: Int64) -> FrameSpan {
        try! FrameSpan(start, end)
    }

    static let lanes = [
        LaneRevision(id: "primary", origin: primary, backingRevision: "a1",
                     mapRevision: "m1", protectionRevision: "p1"),
        LaneRevision(id: "backup", origin: backup, backingRevision: "a2",
                     mapRevision: "m1", protectionRevision: "p2"),
        LaneRevision(id: "silence", origin: nil, backingRevision: "s1",
                     mapRevision: "m1", protectionRevision: "p3"),
    ]

    static func key(source: String = "s1", model: String = "local1",
                    primary: SourceOccurrence = primary, correction: String = "c1",
                    authorization: PrimaryAuthorization = .authorizedSelectedPrimary,
                    map: String = "m1", asset: String = "a1", format: String = "f1",
                    protection: String = "p1", transcript: String = "t1",
                    recipe: String = "r1", cuts: String = "cuts1",
                    lanes: [LaneRevision] = lanes) -> EvidenceKey {
        EvidenceKey(primary: primary, primaryAuthorization: authorization,
                    sourceRevision: source, modelRevision: model,
                    transcriptRevision: transcript, correctionRevision: correction,
                    alignmentRevision: map, assetRevision: asset, formatRevision: format,
                    protectionRevision: protection, outputRecipeRevision: recipe,
                    otherCutsRevision: cuts, lanes: lanes)
    }

    static func proposal(timing: WordTiming = .supported(start: 100, end: 110),
                         sourceBase: Int64 = 100,
                         context: CandidateContext = .contextualFiller) -> CutProposal {
        CutProposal(id: "proposal-1", key: key(),
                    words: [CandidateWord(tokenID: "word-1", timing: timing)],
                    context: context, request: CutRequest(sourceFrames: span(sourceBase, sourceBase + 10)))
    }

    static func proof(key: EvidenceKey = key(), protection: ProtectionProof = .complete([]),
                      backupProtection: ProtectionProof = .complete([]),
                      mode: CutMode = .shorten,
                      fade: [FrameSpan] = [], fadeLength: Int64 = 0,
                      backupBacked: Bool = true, backupOrigin: SourceOccurrence = backup,
                      endpointError: Int64 = 1, sourceBase: Int64 = 100,
                      gridBase: Int64 = 200, coverageEnd: Int64 = 500) -> CutFootprint {
        CutFootprint(key: key, grid: span(gridBase, gridBase + 10), outputRate: 48_000,
                     effect: mode == .shorten ? .shorten(removedOutputFrames: 10) :
                        .lift(reservedOutputFrames: 10), lanes: [
            .audio(id: "primary", origin: primary, coverage: span(1, coverageEnd),
                   removal: span(sourceBase, sourceBase + 10),
                   fades: FadeFootprint(fadeOut: fadeLength > 0 ? fade.first : nil, mergedFinal: fade),
                   protection: protection, backed: true,
                   fadeOutOutputFrames: fadeLength, fadeInOutputFrames: 0,
                   endpointErrorOutputFrames: endpointError),
            .audio(id: "backup", origin: backupOrigin, coverage: span(1, coverageEnd),
                   removal: span(sourceBase + 20, sourceBase + 30),
                   fades: FadeFootprint(fadeOut: fadeLength > 0 ? fade.first : nil, mergedFinal: fade),
                   protection: backupProtection, backed: backupBacked,
                   fadeOutOutputFrames: fadeLength, fadeInOutputFrames: 0,
                   endpointErrorOutputFrames: endpointError),
            .intentionalSilence(id: "silence", gridCoverage: span(1, coverageEnd)),
        ])
    }

    @Test("Analysis creates only inert decisions, never an active edit")
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

    @Test("A hundred and twenty disjoint protected-source-frame cases refuse both modes")
    func protectionMatrix() {
        for i in 0..<120 {
            let base = Int64(100 + i * 13)
            let protectedFrame = i.isMultiple(of: 2) ? base : base + 29
            let lane = i.isMultiple(of: 2) ? "primary" : "backup"
            let interval = Self.span(protectedFrame, protectedFrame + 1)
            for mode in [CutMode.shorten, .lift] {
                let proof = Self.proof(protection: lane == "primary" ? .complete([interval]) : .complete([]),
                                       backupProtection: lane == "backup" ? .complete([interval]) : .complete([]),
                                       mode: mode, sourceBase: base,
                                       gridBase: base + 100, coverageEnd: 4_000)
                let candidate = Self.proposal(timing: .supported(start: base, end: base + 10),
                                               sourceBase: base)
                let request = CutRequest(sourceFrames: candidate.request.sourceFrames, mode: mode)
                #expect(throws: CutRefusal.protectedFrame(lane)) {
                    try CutPolicy.admit(candidate, request: request, currentKey: Self.key(),
                                        affectedLanes: Self.lanes, mapping: FixtureMapper(proof: proof))
                }
            }
        }
    }

    @Test("Every lane and the final merged fade footprint must have current proof")
    func laneAndFadeSafety() {
        let candidate = Self.proposal()
        let request = CutRequest(sourceFrames: Self.span(100, 110), fadeOutFrames: 2)
        let fade = Self.span(498, 500)
        let lastFrame = Self.span(499, 500)
        #expect(throws: CutRefusal.protectedFrame("backup")) {
            try CutPolicy.admit(candidate, request: request, currentKey: Self.key(), affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: Self.proof(
                                    backupProtection: .complete([lastFrame]), fade: [fade], fadeLength: 2)))
        }
        #expect(throws: CutRefusal.uninspectableLane("backup")) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: Self.proof(backupProtection: .unknown)))
        }
        #expect(throws: CutRefusal.uninspectableLane("backup")) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: Self.proof(backupBacked: false)))
        }
        #expect(throws: CutRefusal.uninspectableLane("backup")) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: Self.proof(backupOrigin: Self.primary)))
        }
        #expect(throws: CutRefusal.uninspectableLane("primary")) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: Self.proof(endpointError: 2)))
        }
        #expect(throws: CutRefusal.unsupportedFade("primary")) {
            try CutPolicy.admit(candidate, request: request, currentKey: Self.key(),
                                affectedLanes: Self.lanes, mapping: FixtureMapper(proof: Self.proof()))
        }
        let incomplete = CutFootprint(key: Self.key(), grid: Self.span(200, 210),
                                      outputRate: 48_000, effect: .shorten(removedOutputFrames: 10),
                                      lanes: [.intentionalSilence(
                                        id: "silence", gridCoverage: Self.span(1, 500))])
        #expect(throws: CutRefusal.incompleteLanes) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes, mapping: FixtureMapper(proof: incomplete))
        }
    }

    @Test("Every recorded dependency prevents a stale accept or reactivation")
    func staleKeys() throws {
        let original = Self.key()
        let changed = [
            Self.key(source: "s2"), Self.key(model: "local2"),
            Self.key(primary: Self.backup), Self.key(correction: "c2"),
            Self.key(map: "m2"), Self.key(asset: "a2"), Self.key(format: "f2"),
            Self.key(protection: "p2"), Self.key(transcript: "t2"),
            Self.key(recipe: "r2"), Self.key(cuts: "cuts2"),
            Self.key(lanes: Array(Self.lanes.dropLast())),
        ]
        for key in changed {
            #expect(throws: CutRefusal.staleEvidence) {
                try CutPolicy.admit(Self.proposal(), request: Self.proposal().request,
                                    currentKey: key, affectedLanes: key.lanes,
                                    mapping: FixtureMapper(proof: Self.proof()))
            }
        }
        var journal = ReviewJournal(proposal: Self.proposal())
        let mapping = FixtureMapper(proof: Self.proof())
        try journal.accept(currentKey: original, affectedLanes: Self.lanes, mapping: mapping)
        try journal.restore()
        for key in changed {
            #expect(throws: CutRefusal.staleEvidence) {
                try journal.undo(currentKey: key, affectedLanes: key.lanes, mapping: mapping)
            }
            #expect(journal.cursor == 2)
            #expect(journal.current.decision.activeCut == nil)
        }
        let unauthorized = Self.key(authorization: .notAuthorized)
        let unauthorizedProposal = CutProposal(
            id: "unconsented", key: unauthorized, words: Self.proposal().words,
            context: .contextualFiller, request: Self.proposal().request)
        #expect(throws: CutRefusal.unauthorizedPrimary) {
            try CutPolicy.admit(unauthorizedProposal, request: unauthorizedProposal.request,
                                currentKey: unauthorized, affectedLanes: unauthorized.lanes,
                                mapping: FixtureMapper(proof: Self.proof(key: unauthorized)))
        }
        let missingRevision = Self.key(asset: "")
        let missingRevisionProposal = CutProposal(
            id: "missing-revision", key: missingRevision, words: Self.proposal().words,
            context: .contextualFiller, request: Self.proposal().request)
        #expect(throws: CutRefusal.invalidIdentity) {
            try CutPolicy.admit(missingRevisionProposal, request: missingRevisionProposal.request,
                                currentKey: missingRevision, affectedLanes: missingRevision.lanes,
                                mapping: FixtureMapper(proof: Self.proof(key: missingRevision)))
        }
    }

    @Test("Restore is inactive; safe undo and redo recreate identical history and parameters")
    func history() throws {
        let mapping = FixtureMapper(proof: Self.proof())
        var journal = ReviewJournal(proposal: Self.proposal())
        let initial = journal.current
        try journal.accept(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        let accepted = journal.current
        try journal.restore()
        let restored = journal.current
        #expect(restored.decision.activeCut == nil)
        try journal.undo(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        #expect(journal.current == accepted)
        try journal.undo(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        #expect(journal.current == initial)
        try journal.redo(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        #expect(journal.current == accepted)
        try journal.redo(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        #expect(journal.current == restored)
        #expect(journal.transitions.map(\.actionName) == ["Accept proposal-1", "Restore proposal-1"])
        #expect(journal.cursor == 2)
    }

    @Test("Lift preserves exactly the shared output duration but never waives protection")
    func liftDuration() throws {
        let candidate = Self.proposal()
        let request = CutRequest(sourceFrames: candidate.request.sourceFrames, mode: .lift)
        let approved = try CutPolicy.admit(candidate, request: request, currentKey: Self.key(),
                                           affectedLanes: Self.lanes,
                                           mapping: FixtureMapper(proof: Self.proof(mode: .lift)))
        #expect(approved.footprint.effect == .lift(reservedOutputFrames: 10))
        #expect(approved.footprint.grid == Self.span(200, 210))
        #expect(throws: CutRefusal.invalidGrid) {
            try CutPolicy.admit(candidate, request: request, currentKey: Self.key(),
                                affectedLanes: Self.lanes, mapping: FixtureMapper(proof: Self.proof()))
        }
        let shortGap = CutFootprint(key: Self.key(), grid: Self.span(200, 210),
                                    outputRate: 48_000, effect: .lift(reservedOutputFrames: 9),
                                    lanes: Self.proof(mode: .lift).lanes)
        #expect(throws: CutRefusal.invalidGrid) {
            try CutPolicy.admit(candidate, request: request, currentKey: Self.key(),
                                affectedLanes: Self.lanes, mapping: FixtureMapper(proof: shortGap))
        }
    }

    @Test("Reject, adjust and abstain change only the named proposal decision")
    func reviewDecisions() throws {
        let mapping = FixtureMapper(proof: Self.proof())
        var journal = ReviewJournal(proposal: Self.proposal())
        try journal.adjust(CutRequest(sourceFrames: Self.span(101, 109)))
        #expect(journal.current.decision == .adjusted)
        #expect(journal.current.decision.activeCut == nil)
        try journal.reject()
        #expect(journal.current.decision == .rejected)
        try journal.undo(currentKey: Self.key(), affectedLanes: Self.lanes, mapping: mapping)
        #expect(journal.current.decision == .adjusted)
        try journal.abstain()
        #expect(journal.current.decision == .abstained)
        #expect(journal.transitions.map(\.actionName) == [
            "Adjust proposal-1", "Abstain proposal-1",
        ])
    }

    @Test("Unsupported boundaries, an ambiguous inverse and missing silence cannot activate")
    func unsupported() {
        let candidate = Self.proposal(timing: .hallucinated)
        #expect(throws: CutRefusal.unsupportedWord) {
            try CutPolicy.admit(candidate, request: candidate.request, currentKey: Self.key(),
                                affectedLanes: Self.lanes, mapping: FixtureMapper(proof: Self.proof()))
        }
        let ambiguous = CutFootprint(key: Self.key(), grid: Self.span(200, 210),
                                     outputRate: 48_000, effect: .shorten(removedOutputFrames: 10),
                                     lanes: [
                                        .unsupported(id: "primary"),
                                        .unsupported(id: "backup"),
                                        .intentionalSilence(id: "silence", gridCoverage: Self.span(1, 500)),
                                     ])
        #expect(throws: CutRefusal.uninspectableLane("primary")) {
            try CutPolicy.admit(Self.proposal(), request: Self.proposal().request,
                                currentKey: Self.key(), affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: ambiguous))
        }
        var proof = Self.proof()
        proof = CutFootprint(key: Self.key(), grid: proof.grid, outputRate: proof.outputRate,
                             effect: proof.effect,
                             lanes: Array(proof.lanes.dropLast()) +
                                [.intentionalSilence(id: "silence", gridCoverage: Self.span(1, 199))])
        #expect(throws: CutRefusal.uninspectableLane("silence")) {
            try CutPolicy.admit(Self.proposal(), request: Self.proposal().request,
                                currentKey: Self.key(), affectedLanes: Self.lanes,
                                mapping: FixtureMapper(proof: proof))
        }
    }
}
