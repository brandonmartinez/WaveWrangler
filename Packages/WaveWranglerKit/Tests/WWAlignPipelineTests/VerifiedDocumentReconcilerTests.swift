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
    private func seedDependent(
        _ fixture: PipelineFixture,
        map: MapRevisionReference,
        label: String
    ) async -> (DerivedSlot, DerivedAssetKey) {
        let asset = AssetSpec(kind: "reconcile-\(label)", revision: 1)
        let slot = DerivedSlot("reconcile-\(label)")
        let key = DerivedAssetKey(asset: asset, map: map)
        await fixture.coordinator.setAssetRevision(asset)
        #expect(await fixture.coordinator.submit(slot, key: key) {
            Data(label.utf8)
        }.outcome == .published(key))
        return (slot, key)
    }

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

    @Test func verifiedSaveSupersedesSuspendedAdoptionWithoutRevivingDependents() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "reconcile-save-race")
        let report = try await fixture.analyse(preferredReference: "ref")
        let first = try await fixture.acceptAndActivate(
            report, [fixture.epochs[1]: ConcurrencyTests.truth]
        )
        let dependent = await seedDependent(fixture, map: first.revision, label: "save-old")
        let second = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: MapCurrencyTests.other]
        )
        let reconciler = VerifiedDocumentReconciler()
        let entered = ReconciliationGate()
        let release = ReconciliationGate()
        let adoption = Task {
            try await reconciler.reconcile(
                resolve: {
                    await entered.open()
                    await release.wait()
                },
                publish: {
                    try await fixture.pipeline.activate(model: first.model, episode: fixture.episodeID)
                }
            )
        }
        await entered.wait()
        #expect(try await reconciler.reconcile(
            resolve: {},
            publish: {
                try await fixture.pipeline.activate(second)
            }
        ))
        await release.open()
        #expect(try await !adoption.value)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == second.revision.revision)
        #expect(await fixture.coordinator.state(of: dependent.0) == .stale(
            dependent.1, reasons: [.mapChanged(fixture.episodeID)]
        ))
        #expect(await fixture.coordinator.readyPayload(for: dependent.0) == nil)
    }

    @Test func undoAndRedoSupersedeSuspendedAdoptionsWithoutRevivingDependents() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "reconcile-history-race")
        let report = try await fixture.analyse(preferredReference: "ref")
        let first = try await fixture.acceptAndActivate(
            report, [fixture.epochs[1]: ConcurrencyTests.truth]
        )
        let second = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: MapCurrencyTests.other]
        )
        try await fixture.pipeline.activate(second)
        let reconciler = VerifiedDocumentReconciler()

        let redoDependent = await seedDependent(fixture, map: second.revision, label: "undo-old")
        let undoEntered = ReconciliationGate()
        let undoRelease = ReconciliationGate()
        let olderBeforeUndo = Task {
            try await reconciler.reconcile(
                resolve: {
                    await undoEntered.open()
                    await undoRelease.wait()
                },
                publish: {
                    try await fixture.pipeline.activate(model: second.model, episode: fixture.episodeID)
                }
            )
        }
        await undoEntered.wait()
        #expect(try await reconciler.reconcile(
            resolve: {},
            publish: {
                try await fixture.pipeline.activate(model: first.model, episode: fixture.episodeID)
            }
        ))
        await undoRelease.open()
        #expect(try await !olderBeforeUndo.value)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == first.revision.revision)
        #expect(await fixture.coordinator.state(of: redoDependent.0) == .stale(
            redoDependent.1, reasons: [.mapChanged(fixture.episodeID)]
        ))
        #expect(await fixture.coordinator.readyPayload(for: redoDependent.0) == nil)

        let undoDependent = await seedDependent(fixture, map: first.revision, label: "redo-old")
        let redoEntered = ReconciliationGate()
        let redoRelease = ReconciliationGate()
        let olderBeforeRedo = Task {
            try await reconciler.reconcile(
                resolve: {
                    await redoEntered.open()
                    await redoRelease.wait()
                },
                publish: {
                    try await fixture.pipeline.activate(model: first.model, episode: fixture.episodeID)
                }
            )
        }
        await redoEntered.wait()
        #expect(try await reconciler.reconcile(
            resolve: {},
            publish: {
                try await fixture.pipeline.activate(model: second.model, episode: fixture.episodeID)
            }
        ))
        await redoRelease.open()
        #expect(try await !olderBeforeRedo.value)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == second.revision.revision)
        #expect(await fixture.coordinator.state(of: undoDependent.0) == .stale(
            undoDependent.1, reasons: [.mapChanged(fixture.episodeID)]
        ))
        #expect(await fixture.coordinator.readyPayload(for: undoDependent.0) == nil)
    }

    @Test func cancelledReconciliationCannotLeakItsPublication() async throws {
        let reconciler = VerifiedDocumentReconciler()
        let entered = ReconciliationGate()
        let release = ReconciliationGate()
        let log = PublicationLog()
        let cancelled = Task {
            try await reconciler.reconcile(
                resolve: {
                    await entered.open()
                    await release.wait()
                },
                publish: {
                    await log.record(1)
                }
            )
        }
        await entered.wait()
        cancelled.cancel()
        await release.open()
        do {
            _ = try await cancelled.value
            Issue.record("cancelled reconciliation unexpectedly completed")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(try await reconciler.reconcile(
            resolve: {},
            publish: {
                await log.record(2)
            }
        ))
        #expect(await log.values() == [2])
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
