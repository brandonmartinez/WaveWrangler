import Foundation
import Testing
import WWCore
import WWDerived
@testable import WWAlignPipeline

private actor ReconciliationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor PublicationLog {
    private var revisions: [Int] = []
    func record(_ revision: Int) { revisions.append(revision) }
    func values() -> [Int] { revisions }
}

@Suite("Verified document reconciliation")
struct VerifiedDocumentReconcilerTests {
    @Test func olderSourceResolutionCannotPublishAfterANewerDocument() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "reconcile-race")
        let report = try await fixture.analyse(preferredReference: "ref")
        let first = try await fixture.acceptAndActivate(
            report, [fixture.epochs[1]: ConcurrencyTests.truth]
        )
        let second = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: MapCurrencyTests.other]
        )
        let reconciler = VerifiedDocumentReconciler()
        let entered = ReconciliationGate()
        let release = ReconciliationGate()
        let log = PublicationLog()
        let old = Task {
            try await reconciler.reconcile(
                resolve: {
                    await entered.open()
                    await release.wait()
                },
                publish: {
                    await log.record(1)
                    try await fixture.pipeline.activate(model: first.model, episode: fixture.episodeID)
                }
            )
        }
        await entered.wait()
        let newer = try await reconciler.reconcile(
            resolve: {},
            publish: {
                await log.record(2)
                try await fixture.pipeline.activate(model: second.model, episode: fixture.episodeID)
            }
        )
        await release.open()
        #expect(newer)
        #expect(try await !old.value)
        #expect(await log.values() == [2])
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == second.revision.revision)
    }

    @Test func verifiedModelWithNoAcceptedRevisionClearsIdentityAndDependents() async throws {
        let fixture = try await PipelineFixture([], label: "reconcile-nil")
        let map = MapRevisionReference(episode: fixture.episodeID, revision: 1)
        let asset = AssetSpec(kind: "synthetic", revision: 1)
        let slot = DerivedSlot("synthetic")
        let key = DerivedAssetKey(asset: asset, map: map)
        await fixture.coordinator.setAssetRevision(asset)
        await fixture.coordinator.acceptMap(map)
        #expect(await fixture.coordinator.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))
        let reconciler = VerifiedDocumentReconciler()
        #expect(try await reconciler.reconcile(
            resolve: {},
            publish: {
                try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
            }
        ))
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == nil)
        #expect(await fixture.coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(fixture.episodeID)]))
        #expect(await fixture.coordinator.readyPayload(for: slot) == nil)
    }
}
