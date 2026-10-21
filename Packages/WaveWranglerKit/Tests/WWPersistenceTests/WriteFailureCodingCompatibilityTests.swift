import Foundation
import Testing
import WWPersistence

@Suite("Write failure coding compatibility")
struct WriteFailureCodingCompatibilityTests {
    @Test func americanSpellingPreservesTheStoredCancellationValue() throws {
        let legacy = Data(#""cancelled""#.utf8)
        #expect(try JSONDecoder().decode(WriteFailureKind.self, from: legacy) == .canceled)
        #expect(try JSONEncoder().encode(WriteFailureKind.canceled) == legacy)
        #expect(WriteFailureKind(classifying: CocoaError(.userCancelled)) == .canceled)
    }
}
