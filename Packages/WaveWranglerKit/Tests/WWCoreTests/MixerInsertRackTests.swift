import Foundation
import Testing
import WWCore

@Suite("Positioned mixer insert racks")
struct MixerInsertRackTests {
    private func effect() -> AudioUnitSlot {
        AudioUnitSlot(component: .init(type: 0x61756678, subtype: 0x74657374, manufacturer: 0x74657374))
    }

    @Test func legacyRowsAndSharedTrailingBlank() throws {
        let a = effect(), b = effect()
        #expect(MixerInsertRack.rowCount(in: [[], []]) == 1)
        #expect(MixerInsertRack.rowCount(in: [[a, b], []]) == 3)
        let sparse = try MixerInsertRack.adding(effect(), at: 4, to: [a, b])
        #expect(sparse.map(\.rackPosition) == [0, 1, 4])
        #expect(MixerInsertRack.rowCount(in: [sparse, []]) == 6)
        #expect(MixerInsertRack.isValid(sparse))
    }

    @Test func removalAndBackfillPreservePositionsAndState() throws {
        let a = effect(), b = effect(), c = effect()
        let removed = try MixerInsertRack.removing(a.id, from: [a, b])
        #expect(removed.map(\.rackPosition) == [1])
        let filled = try MixerInsertRack.adding(c, at: 0, to: removed)
        #expect(filled.map(\.id) == [c.id, b.id])
        #expect(filled.map(\.rackPosition) == [0, 1])
        let replaced = try MixerInsertRack.replacing(b.id, with: a, in: filled)
        #expect(replaced.map(\.id) == [c.id, a.id])
        #expect(replaced.map(\.rackPosition) == [0, 1])
        #expect(try JSONDecoder().decode([AudioUnitSlot].self, from: JSONEncoder().encode(replaced)) == replaced)
    }

    @Test func movesLeaveGapsAndReorderOccupiedRows() throws {
        let a = effect(), b = effect()
        let moved = try MixerInsertRack.moving(a.id, to: 3, in: [a, b])
        #expect(moved.map(\.id) == [b.id, a.id])
        #expect(moved.map(\.rackPosition) == [1, 3])
        let reordered = try MixerInsertRack.moving(a.id, to: 1, in: moved)
        #expect(reordered.map(\.id) == [a.id, b.id])
        #expect(reordered.map(\.rackPosition) == [1, 3])
    }

    @Test func occupiedMovesShiftAllInterveningEffectsAndPreserveSparseRows() throws {
        let a = effect(), b = effect(), c = effect(), d = effect()
        let slots = try MixerInsertRack.adding(d, at: 63, to: [a, b, c])
        let earlier = try MixerInsertRack.moving(d.id, to: 0, in: slots)
        #expect(earlier.map(\.id) == [d.id, a.id, b.id, c.id])
        #expect(earlier.map(\.rackPosition) == [0, 1, 2, 63])
        #expect(MixerInsertRack.isValid(earlier))
        let later = try MixerInsertRack.moving(d.id, to: 63, in: earlier)
        #expect(later == slots)
        #expect(try MixerInsertRack.moving(b.id, to: 1, in: slots) == slots)
        let full = (0..<64).map { _ in effect() }
        let fullMove = try MixerInsertRack.moving(full[63].id, to: 0, in: full)
        #expect(fullMove.map(\.id) == [full[63].id] + full.prefix(63).map(\.id))
        #expect(MixerInsertRack.isValid(fullMove))
    }

    @Test func liveBypassComparisonStillRejectsStateIdentityAndOrderChanges() throws {
        let a = effect(), b = effect()
        var bypassed = a
        bypassed.bypassed = true
        #expect(MixerInsertRack.hasSameProcessingState([a, b], [bypassed, b]))
        #expect(!MixerInsertRack.hasSameProcessingState([a, b], [b, a]))
        #expect(!MixerInsertRack.hasSameProcessingState([a], [b]))
        bypassed.documentState = try PropertyListSerialization.data(fromPropertyList: ["gain": 1],
            format: .binary, options: 0)
        #expect(!MixerInsertRack.hasSameProcessingState([a], [bypassed]))
    }

    @Test func invalidPositionsCollisionsAndStaleEditsThrow() throws {
        let a = effect()
        for row in [-1, 64, Int.max] {
            #expect(throws: MixerInsertRack.Failure.self) { try MixerInsertRack.adding(effect(), at: row, to: []) }
        }
        #expect(throws: MixerInsertRack.Failure.self) { try MixerInsertRack.adding(effect(), at: 0, to: [a]) }
        #expect(throws: MixerInsertRack.Failure.self) { try MixerInsertRack.moving(effect().id, to: 1, in: [a]) }
        var b = effect()
        b.rackPosition = 0
        #expect(!MixerInsertRack.isValid([a, b]))
        b.rackPosition = 63
        #expect(MixerInsertRack.isValid([a, b]))
        #expect(MixerInsertRack.rowCount(in: [[a, b]]) == 65)
    }
}
