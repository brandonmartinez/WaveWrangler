import Foundation
import Synchronization
import Testing
import WWCore
import WWOrganizer
@testable import WWPersistence

private typealias ShowCoder = JSONEnvelopeCoder<ShowDocumentModel>
private typealias ShowSession = CanonicalDocumentSession<ShowCoder>

/// Timing families. Run one at a time in the serialized timing pass (`WW_TIMING_TESTS=1`), never alongside
/// the parallel suite.
@Suite("M1 durability holdout — timing", .serialized, .enabled(if: Holdout.enabled && TimingGate.enabled, "WW_HOLDOUT=1 WW_TIMING_TESTS=1"))
struct HoldoutTimingTests {
    // MARK: DUR-002 autosave ON edit-to-quiescent coherent checkpoint

    @Test func dur002QuiescentCheckpoint() async {
        let result = await runFamily(
            "M1-DUR-002", calibration: 20, holdout: 100,
            label: "headless WWPersistence on the claimed host (no native NSDocument scheduling)",
            notes: ["Default ON (1 s quiescence). End point = first independent poll (5 ms) that decodes the full expected state from disk: a published canonical revision or an unpublished edit-checkpoint record, labelled by kind. Callback success is not used."],
            timingGate: ("p95 <= 2 s provisional (WW-005)", 2.0)
        ) { _, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = Rig(label: "dur002")
            let model = HoldoutGen.show(&rng)
            let key = DocumentKey.show(model.show.id)
            let url = rig.url()
            let first = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
            let gate = AutosaveGate(AutosavePreference())   // default: ON, 1 s
            let session = ShowSession(key: key, url: url, payload: model, base: first.fingerprint, revision: 1, publisher: rig.publisher, gate: gate)
            let scheduler = QuiescenceScheduler(gate: gate, queue: DispatchQueue(label: "dur002")) { work in
                Task {
                    switch work {
                    case .publish: _ = await session.save(automatic: true)
                    case .editCheckpoint: _ = await session.writeEditCheckpoint()
                    }
                }
            }
            let states = HoldoutGen.edits(1...20, on: model, &rng)
            for state in states {
                await session.edit { _ in state }
                scheduler.noteEdit()
                try await Task.sleep(for: .milliseconds(HoldoutGen.int(0...30, &rng)))
            }
            let expected = try #require(states.last)
            let lastMutation = ContinuousClock.now
            let deadline = lastMutation + .seconds(5)
            while ContinuousClock.now < deadline {
                if let onDisk = decodeShow(url), onDisk.payload == expected {
                    return CaseResult("publishedRevision", seconds: Stats.seconds(.now - lastMutation))
                }
                if let record = rig.recovery.latestEditCheckpoint(for: key), record.unpublished,
                   (try? ShowCoder.show.decode(record.snapshot))?.payload == expected {
                    try check(decodeShow(url)?.payload == model, "edit checkpoint changed canonical bytes")
                    return CaseResult("editCheckpoint", seconds: Stats.seconds(.now - lastMutation))
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            scheduler.cancelPending()
            throw CaseFailure(description: "no coherent checkpoint within 5 s")
        }
        expectAllPassed(result)
    }

    // MARK: SCALE-001 model-level library scale

    @Test func scale001ModelLevel() async throws {
        let notes = ["Model/view-model level (WWPersistence + WWOrganizer), not native windows; reported separately from any native-window run.",
                     "First-open = first decode+validate of each show file in this process (the files were just written, so the OS page cache is warm); warm = second open.",
                     "Zero main-thread provider I/O is not evidenced at this level."]
        let dir = TempDirectory("scale001")
        let docs = dir.sub("Shows")
        var rng = SeededGenerator(seed: Holdout.seed("M1-SCALE-001/fixture", 0))
        // 100 shows (>= 2 episodes each), 1,000 distinct references, collections, >= 1 unavailable show.
        var shows: [ShowDocumentModel] = []
        for index in 0..<100 {
            var show = ShowDocumentModel(show: Show(id: ShowID(Fixtures.uuid(&rng)), title: String(format: "Scale Show %03d", index)))
            for episode in 0..<HoldoutGen.int(2...4, &rng) {
                show = try show.addingEpisode(Episode(id: EpisodeID(Fixtures.uuid(&rng)), title: "Episode \(episode + 1)", number: episode + 1))
            }
            for reference in 0..<10 {
                show = try show.addingSource(SourceRecord(id: SourceID(Fixtures.uuid(&rng)), displayNameHint: "ref-\(index)-\(reference).wav"), to: show.episodes[reference % show.episodes.count].id)
            }
            shows.append(show)
        }
        #expect(Set(shows.flatMap { $0.episodes.flatMap(\.sources).map(\.id) }).count == 1_000)
        let publisher = DocumentPublisher(coder: ShowCoder.show, recovery: nil)
        var urls: [ShowID: URL] = [:]
        for show in shows {
            let url = docs.appending(path: "\(show.show.id).wwshow")
            _ = try publisher.publish(show, revision: 1, key: .show(show.show.id), to: url, target: .newLocation)
            urls[show.show.id] = url
        }
        var library = HoldoutGen.library(shows, &rng)
        library.entries[3].unavailable = UnavailableRecord(note: "Synthetic folder offline", recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let details = Dictionary(uniqueKeysWithValues: shows.map { show in
            (show.show.id, LibraryEntryDetails(state: .available, locationDisplayName: "This Mac › Synthetic",
                                               episodes: show.episodes.map { EpisodeSummary(id: $0.id, number: $0.number, title: $0.title) },
                                               sourceReferenceCount: show.episodes.flatMap(\.sources).count))
        })
        let opener = DocumentOpener<ShowCoder>.show(recovery: nil)
        let fileURLs = urls
        let order = shows.map(\.show.id)
        let openCount = Mutex(0)

        @Sendable func openAndPresent(_ id: ShowID) throws -> Double {
            let start = ContinuousClock.now
            guard case let .editable(document, _) = opener.open(fileURLs[id]!, key: .show(id)) else { throw CaseFailure(description: "open failed") }
            _ = document.payload.episodes.map(ShowSidebarPresentation.episodeRowTitle)
            _ = ShowSidebarPresentation.windowSubtitle(model: document.payload, selectedEpisode: document.payload.episodes.first?.id)
            openCount.withLock { $0 += 1 }
            return Stats.seconds(.now - start)
        }
        let first = await runFamily("M1-SCALE-001", cell: "first-open", calibration: 20, holdout: 100, label: "model-level, claimed host", notes: notes,
                                    timingGate: ("p95 < 1 s (WW-007 provisional)", 1.0)) { index, _ in
            CaseResult("opened", seconds: try openAndPresent(order[index % order.count]))
        }
        let warm = await runFamily("M1-SCALE-001", cell: "warm-open", calibration: 20, holdout: 100, label: "model-level, claimed host", notes: notes,
                                   timingGate: ("p95 < 1 s (WW-007 provisional)", 1.0)) { index, _ in
            CaseResult("opened", seconds: try openAndPresent(order[index % order.count]))
        }
        let state = Mutex(library)
        let interactions = await runFamily("M1-SCALE-001", cell: "interaction", calibration: 20, holdout: 400, label: "model-level, claimed host", notes: notes,
                                           timingGate: ("p95 < 100 ms (WW-007 provisional)", 0.1)) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let kind = ["selectShowEpisode", "toggleCollection", "rename", "filterSidebar"][index % 4]
            let current = state.withLock { $0 }
            let start = ContinuousClock.now
            switch kind {
            case "selectShowEpisode":
                let id = order[HoldoutGen.int(0...(order.count - 1), &rng)]
                let rows = LibraryPresentation.entries(for: .shows, library: current, details: details)
                try check(rows.contains { $0.showID == id }, "row missing")
                _ = details[id]?.episodes?.first
            case "toggleCollection":
                let collection = current.collections[HoldoutGen.int(0...(current.collections.count - 1), &rng)]
                let id = order[HoldoutGen.int(0...(order.count - 1), &rng)]
                let next = collection.showIDs.contains(id) ? try current.removingShows([id], fromCollection: collection.id) : try current.addingShows([id], toCollection: collection.id)
                _ = LibraryPresentation.sidebar(library: next, details: details)
                _ = LibraryPresentation.entries(for: .collection(collection.id), library: next, details: details)
                state.withLock { $0 = next }
            case "rename":
                let id = order[HoldoutGen.int(0...(order.count - 1), &rng)]
                let next = current.upsertingEntry(showID: id, title: "Renamed \(index)")
                _ = LibraryPresentation.entries(for: .shows, library: next, details: details)
                state.withLock { $0 = next }
            default:
                let index = LibraryIndex.build(from: current, libraryDigest: "scale")
                let matches = index.search(["scale", "show", "alias", "\(HoldoutGen.int(0...99, &rng))"][HoldoutGen.int(0...3, &rng)])
                _ = LibraryPresentation.sidebar(library: current, details: details)
                _ = matches.count
            }
            return CaseResult(kind, seconds: Stats.seconds(.now - start))
        }
        expectAllPassed(first)
        expectAllPassed(warm)
        expectAllPassed(interactions)
        #expect(openCount.withLock { $0 } == first.planned + warm.planned)
    }
}
