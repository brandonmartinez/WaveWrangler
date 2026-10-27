import Darwin
import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWPersistence

/// Gate-ordered, deterministic tests of the job layer. No wall-clock assertions: every interleaving is forced
/// with latches, and nothing blocks a cooperative-pool thread.
@Suite("Derived job coordinator")
struct DerivedJobCoordinatorTests {
    let source = SourceID()
    let episode = EpisodeID()
    let slot = DerivedSlot("waveform/host")

    var inputs: DerivedInputs {
        var inputs = DerivedInputs()
        inputs.sources[source] = "t1"
        inputs.acceptedMaps[episode] = 1
        inputs.recipes["align"] = 1
        inputs.assets["waveform"] = 1
        inputs.assets["onsets"] = 1
        return inputs
    }

    func key(kind: String = "waveform", token: String = "t1", channel: Int? = 0, mapRevision: Int = 1, upstream: [DerivedAssetKey] = []) -> DerivedAssetKey {
        .sample(
            kind: kind,
            sources: [SourceRevision(source: source, token: token)],
            channel: channel,
            map: MapRevisionReference(episode: episode, revision: mapRevision),
            recipe: RecipeReference(name: "align", revision: 1),
            upstream: upstream
        )
    }

    func coordinator(_ directory: TemporaryDirectory, hooks: DerivedCoordinatorTestHooks = DerivedCoordinatorTestHooks()) throws -> DerivedJobCoordinator {
        DerivedJobCoordinator(store: try makeStore(directory), inputs: inputs, testHooks: hooks)
    }

    @MainActor
    @Test func workRunsOffTheMainThreadAndPublishes() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let job = await coordinator.submit(slot, key: key) {
            #expect(pthread_main_np() == 0, "derived work never runs on the main thread")
            return Data("peaks".utf8)
        }
        #expect(await job.outcome == .published(key))
        #expect(await coordinator.state(of: slot) == .ready(key))
        #expect(await coordinator.readyPayload(for: slot) == Data("peaks".utf8))
        #expect(coordinator.store.payload(for: key) == Data("peaks".utf8))
    }

    @Test func cancelingAnOldSubmissionCannotCancelANewerJobWithTheSameKey() async throws {
        let directory = try TemporaryDirectory("same-key-cancellation")
        let coordinator = try coordinator(directory)
        let key = key()
        let firstStarted = Latch(), releaseFirst = Latch()
        let secondStarted = Latch(), releaseSecond = Latch()
        let first = await coordinator.submit(slot, key: key) {
            await firstStarted.open()
            await releaseFirst.wait()
            return Data("first".utf8)
        }
        await firstStarted.wait()
        let second = await coordinator.submit(slot, key: key) {
            await secondStarted.open()
            await releaseSecond.wait()
            return Data("second".utf8)
        }
        await secondStarted.wait()
        await coordinator.cancel(first)
        await releaseSecond.open()
        #expect(await second.outcome == .published(key))
        await releaseFirst.open()
        _ = await first.outcome
        #expect(await coordinator.readyPayload(for: slot) == Data("second".utf8))
    }

    @Test func completeOverviewReusesAcrossOpensAndRebuildsAfterMapOrSourceChanges() async throws {
        let directory = try TemporaryDirectory("overview-cache")
        var current = DerivedInputs()
        current.sources[source] = "metadata:original"
        current.acceptedMaps[episode] = 1
        current.assets["ww.waveform.overview"] = 1
        func overviewKey(token: String, revision: Int) -> DerivedAssetKey {
            DerivedAssetKey(
                asset: AssetSpec(kind: "ww.waveform.overview", revision: 1),
                sources: [SourceRevision(source: source, token: token)],
                format: .current,
                map: MapRevisionReference(episode: episode, revision: revision)
            )
        }
        let first = overviewKey(token: "metadata:original", revision: 1)
        let store = try makeStore(directory)
        let initial = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await initial.submit(slot, key: first) { Data("measured bins".utf8) }.outcome == .published(first))
        await initial.shutdown()

        let reopened = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await reopened.submit(slot, key: first) {
            Issue.record("A verified cached overview should not rescan audio")
            return Data()
        }.outcome == .reused(first))
        #expect(await reopened.readyPayload(for: slot) == Data("measured bins".utf8))
        #expect(await reopened.readyPayload(for: slot, matching: first) == Data("measured bins".utf8))

        await reopened.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await reopened.readyPayload(for: slot) == nil)
        let remapped = overviewKey(token: "metadata:original", revision: 2)
        #expect(await reopened.submit(slot, key: remapped) { Data("remapped bins".utf8) }.outcome == .published(remapped))
        #expect(await reopened.readyPayload(for: slot, matching: first) == nil)
        #expect(await reopened.readyPayload(for: slot, matching: remapped) == Data("remapped bins".utf8))
        await reopened.updateSource(SourceRevision(source: source, token: "metadata:replacement"))
        #expect(await reopened.readyPayload(for: slot) == nil)
        let replaced = overviewKey(token: "metadata:replacement", revision: 2)
        #expect(await reopened.submit(slot, key: replaced) { Data("replacement bins".utf8) }.outcome == .published(replaced))
    }

    @Test func sourceCoverageCacheSurvivesMapRevisionsButRejectsDifferentCoverage() async throws {
        let directory = try TemporaryDirectory("coverage-overview-cache")
        var current = DerivedInputs()
        current.sources[source] = "metadata:original"
        current.acceptedMaps[episode] = 1
        current.assets["ww.waveform.overview"] = 2
        let asset = AssetSpec(kind: "ww.waveform.overview", revision: 2)
        let first = DerivedAssetKey(
            asset: asset, sources: [SourceRevision(source: source, token: "metadata:original")],
            format: .current, coverage: "covered-source-frames-a"
        )
        let revised = DerivedAssetKey(
            asset: asset, sources: [SourceRevision(source: source, token: "metadata:original")],
            format: .current, coverage: "covered-source-frames-b"
        )
        let store = try makeStore(directory)
        let slot = DerivedSlot("source-overview")
        let coordinator = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await coordinator.submit(slot, key: first) {
            Data("source extrema".utf8)
        }.outcome == .published(first))
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.submit(slot, key: first) {
            Issue.record("Changing only aligned positions must not decode the source again")
            return Data()
        }.outcome == .reused(first))
        #expect(await coordinator.submit(slot, key: revised) {
            Data("new coverage".utf8)
        }.outcome == .published(revised))
        #expect(await coordinator.readyPayload(for: slot, matching: first) == nil)
        #expect(await coordinator.readyPayload(for: slot, matching: revised) == Data("new coverage".utf8))
        await coordinator.updateSource(SourceRevision(source: source, token: "metadata:replacement"))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    /// REF-019: accepting a different map while a job is computing makes its late result stale; it is never
    /// published, served or cached.
    @Test func lateResultAfterAMapChangeIsNeverPublished() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let started = Latch()
        let release = Latch()
        let job = await coordinator.submit(slot, key: key) {
            await started.open()
            await release.wait()
            return Data("late".utf8)
        }
        await started.wait()
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        await release.open()
        #expect(await job.outcome == .discardedStale([.mapChanged(episode)]))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
        #expect(coordinator.store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: coordinator.store.stagingDirectory.path).isEmpty)
    }

    /// The invalidation lands after the result is staged and verified but before the commit turn: the
    /// coordinator-side currency check refuses it.
    @Test(arguments: [false, true])
    func invalidationBetweenStagingAndCommitIsRefused(negativeControl: Bool) async throws {
        let directory = try TemporaryDirectory("jobs")
        let staged = Latch()
        let release = Latch()
        let hooks = DerivedCoordinatorTestHooks(beforeCommit: { _, _ in
            await staged.open()
            await release.wait()
        }, skipCurrencyCheck: negativeControl)
        let coordinator = try coordinator(directory, hooks: hooks)
        let key = key()
        let job = await coordinator.submit(slot, key: key) { Data("late".utf8) }
        await staged.wait()
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await release.open()
        let outcome = await job.outcome
        if negativeControl {
            // Without the check, the stale result is published: the ordering test above can fail.
            #expect(outcome == .published(key))
            #expect(coordinator.store.payload(for: key) != nil)
        } else {
            #expect(outcome == .discardedStale([.mapChanged(episode)]))
            #expect(coordinator.store.payload(for: key) == nil)
            #expect(await coordinator.readyPayload(for: slot) == nil)
        }
    }

    /// The invalidation lands after publication: the published result is marked stale and no longer served.
    @Test func invalidationAfterPublicationMarksTheResultStale() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("a".utf8) }.outcome == .published(key))
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func intentionalHistoryMoveRestoresTheCachedKeyThatIsCurrentAgain() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let first = key(mapRevision: 1)
        let second = key(mapRevision: 2)
        #expect(await coordinator.submit(slot, key: first) { Data("first".utf8) }.outcome == .published(first))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.submit(slot, key: second) { Data("second".utf8) }.outcome == .published(second))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .ready(first))
        #expect(await coordinator.readyPayload(for: slot) == Data("first".utf8))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .ready(second))
        #expect(await coordinator.readyPayload(for: slot) == Data("second".utf8))
    }

    @Test func explicitInvalidationIsNeverUndoneByHistoryReconciliation() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))
        await coordinator.invalidate(slot)
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.superseded]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func explicitInvalidationOfAnAlreadyStaleSlotIsNeverUndone() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key(mapRevision: 1)
        #expect(await coordinator.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await coordinator.invalidate(slot)
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
        await coordinator.restoreCachedCurrentSlots()

        guard case .stale = await coordinator.state(of: slot) else {
            Issue.record("explicit invalidation revived an already-stale slot")
            return
        }
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func rejectedStaleSubmissionDoesNotReviveExplicitlyInvalidatedCache() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let original = key()
        let rejected = key(token: "outdated")
        #expect(await coordinator.submit(slot, key: original) { Data("cached".utf8) }.outcome == .published(original))
        await coordinator.invalidate(slot)
        #expect(await coordinator.submit(slot, key: rejected) { Data("never".utf8) }.outcome
                == .discardedStale([.sourceChanged(source)]))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.readyPayload(for: slot) == nil)
        guard case .stale = await coordinator.state(of: slot) else {
            Issue.record("rejected stale submission revived explicitly invalidated cache")
            return
        }
    }

    @Test func invalidatedKeyIsRecomputedBeforeItsCachedPayloadCanBeServed() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("old".utf8) }.outcome == .published(key))
        await coordinator.invalidate(slot)
        let started = Latch()
        let release = Latch()
        let recompute = await coordinator.submit(slot, key: key) {
            await started.open()
            await release.wait()
            return Data("new".utf8)
        }
        await started.wait()
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await release.open()
        #expect(await recompute.outcome == .published(key))
        #expect(await coordinator.readyPayload(for: slot) == Data("new".utf8))
    }

    @Test func aSupersededJobNeverOverwritesItsSuccessor() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let old = key(channel: 0)
        let new = key(channel: 1)
        let started = Latch()
        let release = Latch()
        let first = await coordinator.submit(slot, key: old) {
            await started.open()
            await release.wait()
            return Data("old".utf8)
        }
        await started.wait()
        let second = await coordinator.submit(slot, key: new) { Data("new".utf8) }
        #expect(await second.outcome == .published(new))
        await release.open()
        #expect(await first.outcome == .discardedStale([.superseded]))
        #expect(await coordinator.state(of: slot) == .ready(new))
        #expect(await coordinator.readyPayload(for: slot) == Data("new".utf8))
        #expect(coordinator.store.payload(for: old) == nil)
    }

    @Test func cancellationStopsTheJobWithoutPublishing() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let started = Latch()
        let job = await coordinator.submit(slot, key: key) {
            await started.open()
            // Cancellable wait: returns only through cancellation.
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            await withTaskCancellationHandler {
                for await _ in stream {}
            } onCancel: {
                continuation.finish()
            }
            try Task.checkCancellation()
            return Data("never".utf8)
        }
        await started.wait()
        await coordinator.cancel(slot)
        #expect(await job.outcome == .canceled)
        #expect(await coordinator.state(of: slot) == .canceled(key))
        #expect(coordinator.store.payload(for: key) == nil)
    }

    @Test func aKeyThatIsStaleAtSubmissionNeverRuns() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let runs = Counter()
        let stale = key(token: "old")
        let job = await coordinator.submit(slot, key: stale) {
            runs.increment()
            return Data()
        }
        #expect(await job.outcome == .discardedStale([.sourceChanged(source)]))
        #expect(runs.value == 0)
        #expect(await coordinator.state(of: slot) == .stale(stale, reasons: [.sourceChanged(source)]))
        // The slot never entered `running`: the job was refused before any task could start its work.
        var changes = coordinator.changes.makeAsyncIterator()
        #expect(await changes.next() == DerivedSlotChange(slot: slot, state: .stale(stale, reasons: [.sourceChanged(source)])))
    }

    enum Change: String, CaseIterable, Sendable {
        case sourceRevision, sourceRemoved, format, acceptedMap, clearedMap, recipe, assetRevision, slotInvalidated
    }

    /// Every input a key names invalidates the slot when it changes.
    @Test(arguments: Change.allCases)
    func everyInputChangeMarksDependentWorkStale(_ change: Change) async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("a".utf8) }.outcome == .published(key))
        let expected: StaleReason
        switch change {
        case .sourceRevision:
            await coordinator.updateSource(SourceRevision(source: source, token: "t2")); expected = .sourceChanged(source)
        case .sourceRemoved:
            await coordinator.removeSource(source); expected = .sourceChanged(source)
        case .format:
            await coordinator.setFormat(FormatRevision(interpretationVersion: 99, envelopeVersion: 1)); expected = .formatChanged
        case .acceptedMap:
            await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 3)); expected = .mapChanged(episode)
        case .clearedMap:
            await coordinator.clearAcceptedMap(episode: episode); expected = .mapChanged(episode)
        case .recipe:
            await coordinator.setRecipe(RecipeReference(name: "align", revision: 2)); expected = .recipeChanged("align")
        case .assetRevision:
            await coordinator.setAssetRevision(AssetSpec(kind: "waveform", revision: 2)); expected = .assetRevisionChanged("waveform")
        case .slotInvalidated:
            await coordinator.invalidate(slot); expected = .superseded
        }
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [expected]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
        // Unrelated changes leave a fresh result alone.
        let fresh = DerivedJobCoordinator(store: coordinator.store, inputs: inputs)
        #expect(await fresh.submit(slot, key: key) { Data("a".utf8) }.outcome == .reused(key))
        await fresh.setRecipe(RecipeReference(name: "unrelated", revision: 9))
        await fresh.updateSource(SourceRevision(source: SourceID(), token: "x"))
        #expect(await fresh.state(of: slot) == .ready(key))
    }

    @Test func staleUpstreamCascadesToDependents() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let upstreamSlot = DerivedSlot("waveform")
        let dependentSlot = DerivedSlot("onsets")
        let upstream = key()
        // Names no source itself: it can only become stale through its upstream.
        let dependent = DerivedAssetKey.sample(kind: "onsets", upstream: [upstream])

        // A dependent cannot publish before its upstream is ready.
        #expect(await coordinator.submit(dependentSlot, key: dependent) { Data() }.outcome == .discardedStale([.upstreamChanged]))

        #expect(await coordinator.submit(upstreamSlot, key: upstream) { Data("w".utf8) }.outcome == .published(upstream))
        #expect(await coordinator.submit(dependentSlot, key: dependent) { Data("o".utf8) }.outcome == .published(dependent))
        await coordinator.updateSource(SourceRevision(source: source, token: "t2"))
        #expect(await coordinator.state(of: upstreamSlot) == .stale(upstream, reasons: [.sourceChanged(source)]))
        #expect(await coordinator.state(of: dependentSlot) == .stale(dependent, reasons: [.upstreamChanged]))
    }

    @Test func largeReadyHistoryDoesNotRehashOrRefreshForUnchangedTranscriptionInputs() async throws {
        let directory = try TemporaryDirectory("large-ready-history")
        let coordinator = try coordinator(directory)
        let reference = key(channel: nil)
        let referenceSlot = DerivedSlot("reference")
        #expect(await coordinator.submit(referenceSlot, key: reference) { Data("reference".utf8) }.outcome == .published(reference))
        let tiles = (0..<128).map { index in
            (DerivedSlot("tile/\(index)"), key(kind: "onsets", channel: index, upstream: [reference]))
        }
        for (slot, key) in tiles {
            #expect(await coordinator.submit(slot, key: key) { Data("tile".utf8) }.outcome == .published(key))
        }
        let refreshes = await coordinator.dependencyRefreshCount
        let digests = await coordinator.readyDigestComputationCount
        #expect(digests == tiles.count + 1)
        let began = ContinuousClock.now
        for index in 0..<256 {
            await coordinator.setAssetRevision(AssetSpec(kind: "onsets", revision: 1))
            await coordinator.setRecipe(RecipeReference(name: "align", revision: 1))
            await coordinator.updateSource(SourceRevision(source: source, token: "t1"))
            await coordinator.setFormat(.current)
            await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
            #expect(await coordinator.staleReasons(for: tiles[index % tiles.count].1).isEmpty)
        }
        await coordinator.removeSource(SourceID())
        await coordinator.clearAcceptedMap(episode: EpisodeID())
        let elapsed = began.duration(to: .now)
        #expect(await coordinator.dependencyRefreshCount == refreshes)
        #expect(await coordinator.readyDigestComputationCount == digests,
                "Warm tile dependency checks must not re-encode/hash every previously rendered tile")
        print("DERIVED_WARM_HISTORY ready=\(tiles.count + 1) checks=256 refreshes=0 digestComputations=0 elapsed=\(elapsed)")

        await coordinator.updateSource(SourceRevision(source: source, token: "changed"))
        for (slot, key) in tiles {
            #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.sourceChanged(source), .upstreamChanged]))
        }
        #expect(await coordinator.staleReasons(for: tiles[0].1).contains(.upstreamChanged))
        await coordinator.updateSource(SourceRevision(source: source, token: "t1"))
        #expect(await coordinator.staleReasons(for: tiles[0].1).contains(.upstreamChanged),
                "Restoring inputs alone must not revive an unverified cached dependency")
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: referenceSlot) == .ready(reference))
        for (slot, key) in tiles { #expect(await coordinator.state(of: slot) == .ready(key)) }
        #expect(await coordinator.readyDigestComputationCount == 2 * digests)
        await coordinator.shutdown()
    }

    @Test func duplicateReadyKeysKeepDependenciesCurrentUntilTheirLastSlotIsInvalidated() async throws {
        let directory = try TemporaryDirectory("ready-aliases")
        let coordinator = try coordinator(directory)
        let first = DerivedSlot("first"), second = DerivedSlot("second"), child = DerivedSlot("child")
        let upstream = key()
        let dependent = key(kind: "onsets", upstream: [upstream])
        #expect(await coordinator.submit(first, key: upstream) { Data("source".utf8) }.outcome == .published(upstream))
        #expect(await coordinator.submit(second, key: upstream) { Data() }.outcome == .reused(upstream))
        #expect(await coordinator.submit(child, key: dependent) { Data("child".utf8) }.outcome == .published(dependent))
        await coordinator.invalidate(first)
        #expect(await coordinator.state(of: child) == .ready(dependent))
        #expect(await coordinator.staleReasons(for: dependent).isEmpty)
        await coordinator.invalidate(second)
        #expect(await coordinator.state(of: child) == .stale(dependent, reasons: [.upstreamChanged]))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged])
        #expect(await coordinator.submit(first, key: upstream) { Data("source".utf8) }.outcome == .published(upstream))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: child) == .ready(dependent))

        let entered = Latch(), release = Latch()
        await coordinator.invalidate(first)
        let replacement = await coordinator.submit(first, key: upstream) {
            await entered.open()
            await release.wait()
            return Data("source".utf8)
        }
        await entered.wait()
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged],
                "A running replacement is not a ready dependency even when its key matches the old result")
        await coordinator.cancel(first)
        await release.open()
        #expect(await replacement.outcome == .canceled)
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged])
        await coordinator.shutdown()
    }

    @Test func aRunningDependentIsInvalidatedWithItsUpstream() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let upstreamSlot = DerivedSlot("waveform")
        let dependentSlot = DerivedSlot("onsets")
        let upstream = key()
        #expect(await coordinator.submit(upstreamSlot, key: upstream) { Data("w".utf8) }.outcome == .published(upstream))
        let dependent = DerivedAssetKey.sample(kind: "onsets", upstream: [upstream])
        let started = Latch()
        let release = Latch()
        let job = await coordinator.submit(dependentSlot, key: dependent) {
            await started.open()
            await release.wait()
            return Data("o".utf8)
        }
        await started.wait()
        await coordinator.invalidate(upstreamSlot)
        await release.open()
        #expect(await job.outcome == .discardedStale([.upstreamChanged]))
        #expect(coordinator.store.payload(for: dependent) == nil)
    }

    @Test func aVerifiedCachedAssetIsReusedWithoutRunningWork() async throws {
        let directory = try TemporaryDirectory("jobs")
        let key = key()
        let first = try coordinator(directory)
        #expect(await first.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))

        let runs = Counter()
        let second = try coordinator(directory)
        let job = await second.submit(slot, key: key) {
            runs.increment()
            return Data()
        }
        #expect(await job.outcome == .reused(key))
        #expect(runs.value == 0)
        #expect(await second.readyPayload(for: slot) == Data("cached".utf8))
    }

    @Test func failedWorkPublishesNothing() async throws {
        struct Boom: Error {}
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let job = await coordinator.submit(slot, key: key) { throw Boom() }
        guard case .failed = await job.outcome else {
            Issue.record("expected failure")
            return
        }
        guard case .failed(key, _) = await coordinator.state(of: slot) else {
            Issue.record("expected failed state")
            return
        }
        #expect(coordinator.store.payload(for: key) == nil)
    }

    /// Many slots in flight; a map change mid-flight leaves only current results published, whatever order the
    /// late results arrive in.
    @Test func concurrentLateResultsNeverPublishStaleAssets() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let release = Latch()
        var jobs: [DerivedJob] = []
        var started: [Latch] = []
        for channel in 0..<16 {
            let latch = Latch()
            started.append(latch)
            jobs.append(await coordinator.submit(DerivedSlot("ch\(channel)"), key: key(channel: channel)) {
                await latch.open()
                await release.wait()
                return Data([UInt8(channel)])
            })
        }
        for latch in started { await latch.wait() }
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        let current = (0..<16).map { key(channel: $0, mapRevision: 2) }
        var fresh: [DerivedJob] = []
        for channel in 0..<8 {
            fresh.append(await coordinator.submit(DerivedSlot("ch\(channel)"), key: current[channel]) { Data([UInt8(100 + channel)]) })
        }
        await release.open()
        for (channel, job) in jobs.enumerated() {
            // Re-submitted slots report the late job as superseded; the rest as stale through the map change.
            let reason: StaleReason = channel < 8 ? .superseded : .mapChanged(episode)
            #expect(await job.outcome == .discardedStale([reason]))
            #expect(coordinator.store.payload(for: job.key) == nil)
        }
        for (channel, job) in fresh.enumerated() {
            #expect(await job.outcome == .published(current[channel]))
            #expect(await coordinator.readyPayload(for: DerivedSlot("ch\(channel)")) == Data([UInt8(100 + channel)]))
        }
        for channel in 8..<16 {
            #expect(await coordinator.readyPayload(for: DerivedSlot("ch\(channel)")) == nil)
        }
    }

    // MARK: - Lifetime (review #182 finding 3)

    /// A job whose work ignores cancellation until `release` opens, then records whether it was canceled.
    struct GatedWork {
        let started = Latch()
        let release = Latch()
        let sawCancellation = Flag()

        var work: @Sendable () async throws -> Data {
            { [started, release, sawCancellation] in
                await started.open()
                await release.wait()
                sawCancellation.set(Task.isCancelled)
                return Data("late".utf8)
            }
        }
    }

    @Test func shutdownCancelsRunningWorkAndNothingIsStaged() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let gated = GatedWork()
        let job = await coordinator.submit(slot, key: key, work: gated.work)
        await gated.started.wait()

        let shutdown = Task { await coordinator.shutdown() }
        // Deterministic point: shutdown has canceled every job and marked the running slot canceled.
        for await change in coordinator.changes where change.slot == slot && change.state == .canceled(key) { break }
        await gated.release.open()
        await shutdown.value

        #expect(gated.sawCancellation.value, "the running work observes cancellation")
        #expect(await job.outcome == .canceled)
        #expect(await coordinator.state(of: slot) == .canceled(key))
        #expect(coordinator.store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: coordinator.store.stagingDirectory.path).isEmpty, "nothing staged")
    }

    @Test func aSubmitAfterShutdownNeverRuns() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        await coordinator.shutdown()
        await coordinator.shutdown() // idempotent
        let runs = Counter()
        let job = await coordinator.submit(slot, key: key()) {
            runs.increment()
            return Data("never".utf8)
        }
        #expect(await job.outcome == .canceled)
        #expect(runs.value == 0, "work submitted after shutdown never runs")
        #expect(await coordinator.state(of: slot) == .idle)
        #expect(await coordinator.isShutdown)
    }

    @Test func releasingTheCoordinatorCancelsRunningWork() async throws {
        let directory = try TemporaryDirectory("jobs")
        var coordinator: DerivedJobCoordinator? = try coordinator(directory)
        let store = try #require(coordinator).store
        let key = key()
        let gated = GatedWork()
        let job = await coordinator!.submit(slot, key: key, work: gated.work)
        await gated.started.wait()

        weak let released = coordinator
        coordinator = nil
        // Liveness guard (no wall clock): the last reference is gone, so deinit runs promptly.
        var yields = 0
        while released != nil, yields < 100_000 { await Task.yield(); yields += 1 }
        #expect(released == nil, "the coordinator was released")
        await gated.release.open()

        #expect(await job.outcome == .canceled)
        #expect(gated.sawCancellation.value, "deinit cancels the running work")
        #expect(store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).isEmpty, "nothing staged")
    }
}
