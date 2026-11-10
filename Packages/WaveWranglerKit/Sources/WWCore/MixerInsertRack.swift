import Foundation

/// Occupied rows stay in processing order; empty console rows never instantiate an Audio Unit.
public enum MixerInsertRack {
    public static func hasSameProcessingState(_ lhs: [AudioUnitSlot], _ rhs: [AudioUnitSlot]) -> Bool {
        lhs.map { slot in
            var value = slot
            value.bypassed = false
            return value
        } == rhs.map { slot in
            var value = slot
            value.bypassed = false
            return value
        }
    }

    public enum Failure: LocalizedError {
        case invalidPosition, occupiedPosition, missingSlot, invalidRack

        public var errorDescription: String? {
            switch self {
            case .invalidPosition: "This insert position is outside the 64-slot rack."
            case .occupiedPosition: "This insert position is occupied. Choose a blank slot or replace the effect."
            case .missingSlot: "The effect changed before this edit completed. Try again."
            case .invalidRack: "The insert rack has invalid or duplicate positions."
            }
        }
    }

    public static func position(of slot: AudioUnitSlot, at index: Int) -> Int {
        slot.rackPosition ?? index
    }

    public static func rowCount(in racks: [[AudioUnitSlot]]) -> Int {
        (racks.map { slots in
            slots.enumerated().map { position(of: $0.element, at: $0.offset) + 1 }.max() ?? 0
        }.max() ?? 0) + 1
    }

    public static func isValid(_ slots: [AudioUnitSlot]) -> Bool {
        guard slots.count <= EpisodeMixState.maximumInsertsPerBus, slots.allSatisfy(\.isValid) else { return false }
        let rows = slots.enumerated().map { position(of: $0.element, at: $0.offset) }
        return rows.allSatisfy { (0..<EpisodeMixState.maximumInsertsPerBus).contains($0) }
            && zip(rows, rows.dropFirst()).allSatisfy { $0 < $1 }
            && Set(slots.map(\.id)).count == slots.count
    }

    private static func positioned(_ slots: [AudioUnitSlot]) throws -> [AudioUnitSlot] {
        guard isValid(slots) else { throw Failure.invalidRack }
        return slots.enumerated().map { index, slot in
            var value = slot
            value.rackPosition = position(of: slot, at: index)
            return value
        }
    }

    public static func adding(_ effect: AudioUnitSlot, at row: Int, to slots: [AudioUnitSlot]) throws -> [AudioUnitSlot] {
        guard (0..<EpisodeMixState.maximumInsertsPerBus).contains(row) else { throw Failure.invalidPosition }
        var result = try positioned(slots)
        guard !result.contains(where: { $0.rackPosition == row }) else { throw Failure.occupiedPosition }
        var effect = effect
        effect.rackPosition = row
        result.append(effect)
        result.sort { $0.rackPosition! < $1.rackPosition! }
        guard isValid(result) else { throw Failure.invalidRack }
        return result
    }

    public static func removing(_ id: AudioUnitSlotID, from slots: [AudioUnitSlot]) throws -> [AudioUnitSlot] {
        let result = try positioned(slots)
        guard result.contains(where: { $0.id == id }) else { throw Failure.missingSlot }
        return result.filter { $0.id != id }
    }

    public static func replacing(_ id: AudioUnitSlotID, with effect: AudioUnitSlot,
                                 in slots: [AudioUnitSlot]) throws -> [AudioUnitSlot] {
        var result = try positioned(slots)
        guard let index = result.firstIndex(where: { $0.id == id }) else { throw Failure.missingSlot }
        var effect = effect
        effect.rackPosition = result[index].rackPosition
        result[index] = effect
        guard isValid(result) else { throw Failure.invalidRack }
        return result
    }

    /// Occupied destinations shift the intervening effects; blank destinations leave the source row blank.
    public static func moving(_ id: AudioUnitSlotID, to row: Int, in slots: [AudioUnitSlot]) throws -> [AudioUnitSlot] {
        guard (0..<EpisodeMixState.maximumInsertsPerBus).contains(row) else { throw Failure.invalidPosition }
        var result = try positioned(slots)
        guard let source = result.firstIndex(where: { $0.id == id }) else { throw Failure.missingSlot }
        if let target = result.firstIndex(where: { $0.rackPosition == row }), source != target {
            let rows = result.map(\.rackPosition)
            let moved = result.remove(at: source)
            result.insert(moved, at: target)
            for index in result.indices { result[index].rackPosition = rows[index] }
        } else {
            result[source].rackPosition = row
        }
        result.sort { $0.rackPosition! < $1.rackPosition! }
        return result
    }
}
