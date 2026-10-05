import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Re-review finding 1: the queued-edit replay must keep both sides' changes since the base, or report a
/// conflict (L4) — never silently overwrite the other Mac's work.
@Suite("Queued library edits three-way merge")
struct QueuedLibraryMergeTests {
    let shows = (0..<6).map { Fixtures.show(seed: 3_000 + UInt64($0)) }
    var ids: [ShowID] { shows.map(\.show.id) }

    func library(fav: [Int], aliases: [Int: String] = [:]) -> LibraryModel {
        var model = LibraryModel(
            entries: shows.enumerated().map { LibraryShowEntry(showID: $1.show.id, alias: aliases[$0], lastKnownTitle: $1.show.title) },
            collections: [LibraryCollection(id: CollectionID(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), name: "Fav", showIDs: fav.map { ids[$0] })],
            recentShowIDs: [ids[0], ids[1]]
        )
        model.schemaVersion = SchemaVersion.library
        return model
    }

    func merged(_ base: LibraryModel, _ mine: LibraryModel, _ theirs: LibraryModel) -> (LibraryModel, [String]) {
        let (result, conflicts) = QueuedLibraryEdits.apply(base: base, mine: mine, onto: theirs)
        let missing = QueuedLibraryEdits.missingChanges(base: base, mine: mine, in: result)
            + QueuedLibraryEdits.missingChanges(base: base, mine: theirs, in: result)
        return (result, conflicts + missing)
    }

    @Test func bothSidesAddMembers() {
        let (result, problems) = merged(library(fav: [0, 1]), library(fav: [0, 1, 3]), library(fav: [0, 1, 2]))
        #expect(problems.isEmpty)
        #expect(Set(result.collections[0].showIDs) == Set([0, 1, 2, 3].map { ids[$0] }))
    }

    @Test func addHereRemoveThereAndViceVersa() {
        let (result, problems) = merged(library(fav: [0, 1, 2]), library(fav: [0, 2, 4]), library(fav: [0, 1, 3]))
        #expect(problems.isEmpty)
        #expect(Set(result.collections[0].showIDs) == Set([0, 3, 4].map { ids[$0] }), "removes from both sides and adds from both sides")
    }

    @Test func oneSideReordersOtherAdds() {
        let (result, problems) = merged(library(fav: [0, 1, 2]), library(fav: [2, 1, 0]), library(fav: [0, 1, 2, 3]))
        #expect(problems.isEmpty)
        #expect(result.collections[0].showIDs.filter { [0, 1, 2].map { ids[$0] }.contains($0) } == [2, 1, 0].map { ids[$0] })
        #expect(result.collections[0].showIDs.contains(ids[3]))
    }

    @Test func conflictingOrderIsReported() {
        let (_, problems) = merged(library(fav: [0, 1, 2]), library(fav: [2, 1, 0]), library(fav: [1, 0, 2]))
        #expect(problems.contains { $0.contains("reordered") })
    }

    @Test func bothSidesEditTheSameAlias() {
        let base = library(fav: [0], aliases: [1: "Old"])
        let (_, conflicting) = merged(base, library(fav: [0], aliases: [1: "Mine"]), library(fav: [0], aliases: [1: "Theirs"]))
        #expect(conflicting.contains { $0.contains("changed differently") })
        let (same, agreeing) = merged(base, library(fav: [0], aliases: [1: "Same"]), library(fav: [0], aliases: [1: "Same"]))
        #expect(agreeing.isEmpty && same.entries[1].alias == "Same")
        let (theirsOnly, none) = merged(base, library(fav: [0], aliases: [1: "Old", 2: "Mine"]), library(fav: [0], aliases: [1: "Theirs"]))
        #expect(none.isEmpty && theirsOnly.entries[1].alias == "Theirs" && theirsOnly.entries[2].alias == "Mine")
    }

    @Test func observationsTakeTheNewestWithoutConflict() {
        let base = library(fav: [0])
        var mine = base, theirs = base
        mine.entries[0].lastKnownPublication = PublicationStamp(revision: 5, publicationID: UUID(), checksum: "sha256:a")
        theirs.entries[0].lastKnownPublication = PublicationStamp(revision: 7, publicationID: UUID(), checksum: "sha256:b")
        let (result, problems) = merged(base, mine, theirs)
        #expect(problems.isEmpty)
        #expect(result.entries[0].lastKnownPublication == theirs.entries[0].lastKnownPublication)
    }

    /// Property: whenever the merge reports no conflict, every change from both sides is present and the
    /// result validates.
    @Test func randomizedBothSidesSurvive() throws {
        var conflicts = 0, clean = 0, invalid = 0, silentDrops = 0
        for seed in 0..<500 {
            var rng = SeededGenerator(seed: UInt64(seed) &+ 77)
            let base = library(fav: [0, 1, 2], aliases: [1: "Base"])
            let mine = mutate(base, &rng, tag: "mine")
            let theirs = mutate(base, &rng, tag: "theirs")
            let (result, reported) = QueuedLibraryEdits.apply(base: base, mine: mine, onto: theirs)
            let missing = QueuedLibraryEdits.missingChanges(base: base, mine: mine, in: result)
                + QueuedLibraryEdits.missingChanges(base: base, mine: theirs, in: result)
            if reported.isEmpty {
                clean += 1
                if !missing.isEmpty { silentDrops += 1; Issue.record("seed \(seed) dropped: \(missing)") }
                if (try? LibraryCoder.library.encode(result, revision: 1)) == nil { invalid += 1 }
            } else {
                conflicts += 1
            }
        }
        Evidence.record("queued-merge property: seeds=500 clean=\(clean) conflictsRoutedToL4=\(conflicts) silentDrops=\(silentDrops) invalid=\(invalid)")
        #expect(silentDrops == 0 && invalid == 0 && clean > 0)
    }

    func mutate(_ library: LibraryModel, _ rng: inout SeededGenerator, tag: String) -> LibraryModel {
        var model = library
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: // add member
                let candidate = ids[Int.random(in: 0..<ids.count, using: &rng)]
                if !model.collections[0].showIDs.contains(candidate) { model.collections[0].showIDs.append(candidate) }
            case 1: // remove member
                if !model.collections[0].showIDs.isEmpty { model.collections[0].showIDs.remove(at: Int.random(in: 0..<model.collections[0].showIDs.count, using: &rng)) }
            case 2: model.collections[0].showIDs.shuffle(using: &rng)
            case 3: model.entries[Int.random(in: 0..<model.entries.count, using: &rng)].alias = "\(tag) \(Int.random(in: 0..<3, using: &rng))"
            case 4: model.collections.append(LibraryCollection(name: "\(tag) collection", showIDs: [ids[Int.random(in: 0..<ids.count, using: &rng)]]))
            case 5: model = LibraryReconciler.recordingRecent(ids[Int.random(in: 0..<ids.count, using: &rng)], in: model)
            default: if !model.recentShowIDs.isEmpty { model.recentShowIDs.removeLast() }
            }
        }
        return model
    }
}
