import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Review finding 1: concurrent library operations (user edits, show-save acknowledgements, recents,
/// queued-edit retry) must never lose an edit or report success for an edit that was overwritten.
@Suite("Library concurrency (serialized operations)", .serialized)
struct LibraryConcurrencyTests {
    @Test func concurrentUpdateAcknowledgeAndRecentLoseNothing() async throws {
        let rounds = 100
        var lost = 0, falseSuccess = 0, failures = 0
        let rig = LibraryRig("concurrency")
        let shows = (0..<6).map { Fixtures.show(seed: 2_000 + UInt64($0)) }
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { _ in Fixtures.library(shows: shows, seed: 20) }
        for round in 0..<rounds {
            let stamp = PublicationStamp(revision: round + 2, publicationID: UUID(), checksum: "sha256:round\(round)")
            let collection = "Round \(round)"
            let recent = shows[round % shows.count].show.id
            async let edit = store.update { var l = $0; l.collections.append(LibraryCollection(name: collection)); return l }
            async let ack = store.acknowledgeShowPublication(shows[0].show.id, title: "Ack \(round)", publication: stamp)
            async let recentDone: Void = store.recordRecent(recent)
            let (editResult, ackResult, _) = try await (edit, ack, recentDone)
            let onDisk = try LibraryCoder.library.decode(Data(contentsOf: try #require(await store.currentLibraryURL()))).payload
            let hasCollection = onDisk.collections.contains { $0.name == collection }
            let hasAck = onDisk.entries.first { $0.showID == shows[0].show.id }?.lastKnownPublication == stamp
            let hasRecent = onDisk.recentShowIDs.first == recent || onDisk.recentShowIDs.contains(recent)
            if case .published = editResult { if !hasCollection { falseSuccess += 1 } } else { failures += 1 }
            if case .published? = ackResult { if !hasAck { falseSuccess += 1 } } else { failures += 1 }
            if !(hasCollection && hasAck && hasRecent) { lost += 1 }
            #expect(await store.library == onDisk, "in-memory library equals verified disk truth")
            let digest = RevisionFingerprint.digest(try Data(contentsOf: try #require(await store.currentLibraryURL())))
            #expect(await store.index == LibraryIndex.build(from: onDisk, libraryDigest: digest), "index built from the published payload")
        }
        Evidence.record("library concurrency update+ack+recent rounds=\(rounds) lost=\(lost) falseSuccess=\(falseSuccess) failures=\(failures)")
        #expect(lost == 0 && falseSuccess == 0 && failures == 0)
    }

    @Test func concurrentRetryAndUpdateLoseNothing() async throws {
        let rounds = 100
        var lost = 0, stillPending = 0
        for round in 0..<rounds {
            let offline = try await PendingLibraryEditsTests.OfflineRig()
            try offline.goOffline()
            let store = offline.rig.store()
            _ = await store.load()
            _ = try await store.update(PendingLibraryEditsTests.addCollection("Queued \(round)"))
            try offline.comeBack()
            async let retry = store.retryPendingEdits()
            async let edit = store.update(PendingLibraryEditsTests.addCollection("Online \(round)"))
            _ = try await (retry, edit)
            // If the edit was queued (it ran first), a further retry applies it.
            if await store.pendingEditCount > 0 { _ = await store.retryPendingEdits() }
            let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile)).payload
            let names = Set(onDisk.collections.map(\.name))
            if !(names.contains("Queued \(round)") && names.contains("Online \(round)")) { lost += 1 }
            if await store.pendingEditCount > 0 { stillPending += 1 }
        }
        Evidence.record("library concurrency retry+update rounds=\(rounds) lost=\(lost) stillPending=\(stillPending)")
        #expect(lost == 0 && stillPending == 0)
    }
}
