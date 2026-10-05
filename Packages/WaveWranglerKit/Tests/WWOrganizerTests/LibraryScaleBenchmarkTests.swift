import Foundation
import Testing
import WWCore
@testable import WWOrganizer

/// WW-007 headless scale check (M1-SCALE-001 shape): sidebar model building for 100 shows / 1,000 source
/// references. Records p50/p95 on the current host; the provisional interaction budget is p95 < 100 ms.
/// This is a model-building measurement, not a GUI open/interaction timing.
@Suite("Library scale benchmark", .serialized)
struct LibraryScaleBenchmarkTests {
    static let iterations = 200
    static let interactionBudget = Duration.milliseconds(100)

    static func percentile(_ sorted: [Duration], _ p: Double) -> Duration {
        let rank = Int((p * Double(sorted.count - 1)).rounded(.up))
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test func sidebarAndEntryModelsFor100ShowsAnd1000Refs() {
        let fixture = SyntheticLibraryFixture.make(shows: 100, sourceReferences: 1_000)
        #expect(fixture.library.entries.count == 100)
        #expect(fixture.details.values.compactMap(\.sourceReferenceCount).reduce(0, +) == 1_000)

        let clock = ContinuousClock()
        var samples: [Duration] = []
        var checksum = 0
        let items: [LibrarySidebarItem] = [.shows, .recent, .unavailable] + fixture.library.collections.map { .collection($0.id) }
        for _ in 0..<Self.iterations {
            let elapsed = clock.measure {
                let snapshot = LibraryPresentation.sidebar(library: fixture.library, details: fixture.details)
                checksum &+= snapshot.collectionRows.count
                for item in items {
                    checksum &+= LibraryPresentation.entries(for: item, library: fixture.library, details: fixture.details).count
                }
            }
            samples.append(elapsed)
        }
        samples.sort()
        let p50 = Self.percentile(samples, 0.50)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "WW-007 sidebar+entries (100 shows/1,000 refs, %d iterations): p50 %.3f ms, p95 %.3f ms, max %.3f ms",
                     Self.iterations, Self.milliseconds(p50), Self.milliseconds(p95), Self.milliseconds(samples.last!)))
        #expect(checksum > 0)
        #expect(p95 < Self.interactionBudget)
    }

    /// #106: the model half of one sidebar switch (rows for the selected item, sorted by a column), as the
    /// entry outline does on every switch. The view half is measured natively (scripts/measure-sidebar-switches.sh).
    @Test func sidebarSwitchModelWorkFor100Shows() {
        let fixture = SyntheticLibraryFixture.make(shows: 100, sourceReferences: 1_000)
        let items: [LibrarySidebarItem] = [.shows, .recent, .unavailable] + fixture.library.collections.map { .collection($0.id) }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var checksum = 0
        for index in 0..<Self.iterations {
            let item = index.isMultiple(of: 2) ? LibrarySidebarItem.shows : items[index % items.count]
            let elapsed = clock.measure {
                let rows = LibraryPresentation.entries(for: item, library: fixture.library, details: fixture.details)
                checksum &+= LibraryPresentation.sorted(rows, by: [(.status, true), (.name, true)]).count
            }
            samples.append(elapsed)
        }
        samples.sort()
        let p50 = Self.percentile(samples, 0.50)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "WW-007 sidebar switch model work (100 shows, sorted, %d iterations): p50 %.3f ms, p95 %.3f ms",
                     Self.iterations, Self.milliseconds(p50), Self.milliseconds(p95)))
        #expect(checksum > 0)
        #expect(p95 < Self.interactionBudget)
    }

    @Test func collectionEditPlusRebuildFor100Shows() throws {
        let fixture = SyntheticLibraryFixture.make(shows: 100, sourceReferences: 1_000)
        let collection = try #require(fixture.library.collections.first)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var library = fixture.library
        for index in 0..<Self.iterations {
            let show = fixture.library.entries[index % fixture.library.entries.count].showID
            let elapsed = try clock.measure {
                library = try library.addingShows([show], toCollection: collection.id).movingCollection(collection.id, by: index.isMultiple(of: 2) ? 1 : -1)
                _ = LibraryPresentation.sidebar(library: library, details: fixture.details)
                _ = LibraryPresentation.entries(for: .collection(collection.id), library: library, details: fixture.details)
            }
            samples.append(elapsed)
        }
        samples.sort()
        let p50 = Self.percentile(samples, 0.50)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "WW-007 collection edit + rebuild (100 shows, %d iterations): p50 %.3f ms, p95 %.3f ms",
                     Self.iterations, Self.milliseconds(p50), Self.milliseconds(p95)))
        #expect(p95 < Self.interactionBudget)
    }
}
