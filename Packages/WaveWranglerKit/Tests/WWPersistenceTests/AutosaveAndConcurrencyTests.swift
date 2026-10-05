import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

private func makeSession(_ rig: Rig, seed: UInt64, gate: AutosaveGate? = nil) throws -> (CanonicalDocumentSession<JSONEnvelopeCoder<ShowDocumentModel>>, URL) {
    let model = Fixtures.show(seed: seed)
    let url = rig.url("Session-\(seed).wwshow")
    let receipt = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
    let session = CanonicalDocumentSession(key: .show(model.show.id), url: url, payload: model, base: receipt.fingerprint,
                                           revision: 1, publisher: rig.publisher, gate: gate)
    return (session, url)
}

private final class Counter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@Suite("Autosave policy ON / configurable / OFF", .serialized)
struct AutosavePolicyTests {
    @Test func preferenceDefaultsAndBounds() throws {
        let suite = "WWPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AutosavePreference(defaults: defaults) == AutosavePreference(enabled: true, delaySeconds: 1))
        AutosavePreference(enabled: false, delaySeconds: 5).write(to: defaults)
        #expect(AutosavePreference(defaults: defaults) == AutosavePreference(enabled: false, delaySeconds: 5))
        defaults.set(3.7, forKey: AutosavePreference.delayKey)
        #expect(AutosavePreference(defaults: defaults).delaySeconds == AutosavePreference.defaultDelay)
        #expect(AutosavePreference.enabledKey == "WWAutosaveEnabled")
    }

    @Test func offSchedulesNothingAndKeepsDirtyState() async throws {
        let rig = Rig()
        let gate = AutosaveGate(AutosavePreference(enabled: false))
        let (session, url) = try makeSession(rig, seed: 40, gate: gate)
        let before = try Data(contentsOf: url)
        let ran = Counter()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global()) { _ in ran.increment() }
        try await session.edit { try $0.renamingShow(to: "Off edit") }
        #expect(scheduler.noteEdit() == false)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(ran.count == 0)
        // An automatic save entry arriving while OFF is skipped without writing and is not success-shaped.
        guard case .failure(.cancelled) = await session.save(automatic: true) else { Issue.record("automatic save ran"); return }
        #expect(await session.isDirty)
        #expect(await session.status.state == .autosaveSkipped)
        #expect(await !session.status.state.isVerifiedOnDisk)
        #expect(try Data(contentsOf: url) == before)
        // Explicit Save always works with a valid type.
        guard case let .success(receipt) = await session.save() else { Issue.record("explicit save failed"); return }
        #expect(receipt.revision == 2)
        #expect(await !session.isDirty)
    }

    @Test func workQueuedBeforeTurningOffIsSkipped() async throws {
        let gate = AutosaveGate(AutosavePreference(enabled: true, delaySeconds: 1))
        let ran = Counter(), skipped = Counter()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global(), onSkipped: { skipped.increment() }) { _ in ran.increment() }
        #expect(scheduler.noteEdit())
        try await Task.sleep(for: .milliseconds(200))
        gate.preference.enabled = false
        try await Task.sleep(for: .milliseconds(1300))
        #expect(ran.count == 0)
        #expect(skipped.count == 1)
    }

    @Test func turningOnWithPendingEditsPublishes() async throws {
        let rig = Rig()
        let gate = AutosaveGate(AutosavePreference(enabled: false))
        let (session, url) = try makeSession(rig, seed: 41, gate: gate)
        let published = Counter()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global()) { kind in
            guard kind == .publish else { return }
            Task {
                if case .success = await session.save(automatic: true) { published.increment() }
            }
        }
        try await session.edit { try $0.renamingShow(to: "Pending while off") }
        scheduler.noteEdit()
        gate.preference.enabled = true
        scheduler.reschedulePending()
        try await Task.sleep(for: .milliseconds(1600))
        #expect(published.count == 1)
        #expect(await !session.isDirty)
        guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(document.payload.show.title == "Pending while off")
    }

    @Test func longerDelayStillRecordsRecoveryDraftFirst() async throws {
        let rig = Rig()
        let gate = AutosaveGate(AutosavePreference(enabled: true, delaySeconds: 5))
        let (session, url) = try makeSession(rig, seed: 42, gate: gate)
        let drafts = Counter()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global()) { kind in
            guard kind == .recoveryDraft else { return }
            Task { if await session.writeRecoveryDraft() { drafts.increment() } }
        }
        let before = try Data(contentsOf: url)
        try await session.edit { try $0.renamingShow(to: "Drafted") }
        scheduler.noteEdit()
        try await Task.sleep(for: .milliseconds(1500))
        scheduler.cancelPending()
        #expect(drafts.count == 1)
        #expect(try Data(contentsOf: url) == before, "a draft is not a save")
        let draft = try #require(try rig.recovery.draft(for: session.key))
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(draft.bytes).payload.show.title == "Drafted")
        #expect(await session.isDirty)
    }

    /// WW-005 provisional gate: ≤2 s from the last edit to a coherent, independently read-back checkpoint.
    /// Headless measurement on this host; it does not establish native NSDocument scheduling timing.
    @Test func editToQuiescentCheckpointLatency() async throws {
        let rig = Rig()
        // Default policy: publication after 1 s quiescence.
        let gate = AutosaveGate(AutosavePreference(enabled: true, delaySeconds: 1))
        let (session, url) = try makeSession(rig, seed: 43, gate: gate)
        let (stream, continuation) = AsyncStream<ContinuousClock.Instant>.makeStream()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global()) { kind in
            guard kind == .publish else { return }
            Task {
                if case .success = await session.save(automatic: true) { continuation.yield(.now) }
            }
        }
        var iterator = stream.makeAsyncIterator()
        var latencies: [Double] = []
        for sample in 0..<12 {
            for burst in 0..<4 {
                try await session.edit { try $0.renamingShow(to: "Sample \(sample) edit \(burst)") }
                scheduler.noteEdit()
                try await Task.sleep(for: .milliseconds(40))
            }
            try await session.edit { try $0.renamingShow(to: "Sample \(sample) final") }
            scheduler.noteEdit()
            let lastEdit = ContinuousClock.now
            let verified = try #require(await iterator.next())
            // Independent read-back of coherent disk truth.
            let decoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url))
            #expect(decoded.payload.show.title == "Sample \(sample) final")
            latencies.append(Stats.seconds(verified - lastEdit))
        }
        Evidence.record("autosave edit-to-quiescent verified checkpoint (delay 1 s, publication) \(Stats.summary(latencies)) [headless WWPersistence, this host]")
        #expect(Stats.percentile(latencies, 95) <= 2.0)
        #expect(latencies.max() ?? 99 <= 2.0)

        // Longer configured delay (5 s): the device-local recovery draft lands first.
        gate.preference = AutosavePreference(enabled: true, delaySeconds: 5)
        let (draftStream, draftContinuation) = AsyncStream<ContinuousClock.Instant>.makeStream()
        let draftScheduler = QuiescenceScheduler(gate: gate, queue: .global()) { kind in
            guard kind == .recoveryDraft else { return }
            Task { if await session.writeRecoveryDraft() { draftContinuation.yield(.now) } }
        }
        var draftIterator = draftStream.makeAsyncIterator()
        var draftLatencies: [Double] = []
        for sample in 0..<5 {
            try await session.edit { try $0.renamingShow(to: "Draft sample \(sample)") }
            draftScheduler.noteEdit()
            let lastEdit = ContinuousClock.now
            let written = try #require(await draftIterator.next())
            let draft = try #require(try rig.recovery.draft(for: session.key))
            #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(draft.bytes).payload.show.title == "Draft sample \(sample)")
            draftLatencies.append(Stats.seconds(written - lastEdit))
            draftScheduler.cancelPending()
        }
        Evidence.record("autosave edit-to-recovery-draft (delay 5 s configured) \(Stats.summary(draftLatencies)) [headless WWPersistence, this host]")
        #expect((draftLatencies.max() ?? 99) <= 2.0)
        scheduler.cancelPending()
    }

    @Test func publicationPipelineCost() throws {
        let rig = Rig()
        var model = Fixtures.show(seed: 44, episodes: 6, sourcesPerEpisode: 8)
        let url = rig.url()
        var base = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation).fingerprint
        var samples: [Double] = []
        for revision in 2...201 {
            model = try model.renamingShow(to: "Rev \(revision)")
            let start = ContinuousClock.now
            base = try rig.publisher.publish(model, revision: revision, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base)).fingerprint
            samples.append(Stats.seconds(.now - start))
        }
        Evidence.record("publication pipeline (base check+stage+fsync+verify+retain prior+replace+read-back), 6 episodes/48 sources: \(Stats.summary(samples))")
        #expect(Stats.percentile(samples, 95) < 0.5)
    }
}

@Suite("Concurrent writers")
struct ConcurrencyTests {
    @Test func twoInstancesOnSameFileConflictAndBothArePreserved() async throws {
        let rig = Rig()
        let (first, url) = try makeSession(rig, seed: 50)
        let base = await first.base
        let second = CanonicalDocumentSession(key: first.key, url: url, payload: await first.payload, base: base, revision: 1, publisher: rig.publisher)
        try await first.edit { try $0.renamingShow(to: "First") }
        try await second.edit { try $0.renamingShow(to: "Second") }
        guard case .success = await first.save() else { Issue.record("first failed"); return }
        guard case let .failure(.conflict(conflict)) = await second.save() else { Issue.record("no conflict"); return }
        #expect(await second.isDirty)
        #expect(await second.status.state == .conflict(onDiskRevision: 2, missing: false))
        // Keep mine as a new document: both revisions now exist, nothing overwritten.
        guard case .success = await second.duplicate(to: rig.url("Second copy.wwshow")) else { Issue.record("copy failed"); return }
        guard case let .editable(theirs, _) = rig.opener.open(url), case let .editable(mine, _) = rig.opener.open(rig.url("Second copy.wwshow"))
        else { Issue.record("unreadable"); return }
        #expect(theirs.payload.show.title == "First" && mine.payload.show.title == "Second")
        #expect(conflict.preservedCandidate != nil)
    }

    @Test func racingSavesExactlyOneWinsPerRound() async throws {
        let rig = Rig()
        let rounds = 100
        var wins = 0, conflicts = 0, other = 0, preserved = 0
        for round in 0..<rounds {
            let (a, url) = try makeSession(rig, seed: 1000 + UInt64(round))
            let b = CanonicalDocumentSession(key: a.key, url: url, payload: await a.payload, base: await a.base, revision: 1, publisher: rig.publisher)
            try await a.edit { try $0.renamingShow(to: "A") }
            try await b.edit { try $0.renamingShow(to: "B") }
            async let ra = a.save()
            async let rb = b.save()
            let results = await [ra, rb]
            for result in results {
                switch result {
                case .success: wins += 1
                case let .failure(.conflict(conflict)): conflicts += 1; if conflict.preservedCandidate != nil { preserved += 1 }
                default: other += 1
                }
            }
            guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("round \(round) unreadable"); continue }
            #expect(["A", "B"].contains(document.payload.show.title))
        }
        Evidence.record("concurrent writers (two in-process instances, NSFileCoordinator) rounds=\(rounds) wins=\(wins) conflicts=\(conflicts) preserved=\(preserved) other=\(other) [simulated/local]")
        #expect(wins == rounds && conflicts == rounds && preserved == rounds && other == 0)
    }
}
