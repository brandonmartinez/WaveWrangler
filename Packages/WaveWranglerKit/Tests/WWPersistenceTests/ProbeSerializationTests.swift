import Foundation
import Testing
import WWPersistence
@testable import WWPersistenceProbe

@Suite("Persistence probe wire compatibility")
struct ProbeSerializationTests {
    @Test(arguments: [
        (PublicationError.canceled, ["result": "cancelled"]),
        (.acknowledgmentUncertain("unverified"),
         ["result": "acknowledgementUncertain", "detail": "unverified"]),
    ])
    func publicationErrorResultsKeepLegacyJSONValues(
        _ error: PublicationError,
        _ expected: [String: String]
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: describe(error), options: [.sortedKeys])
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(result == expected)
    }
}
