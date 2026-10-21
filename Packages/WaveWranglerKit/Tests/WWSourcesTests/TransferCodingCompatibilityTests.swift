import Foundation
import Testing
import WWSources

@Suite("Transfer coding compatibility")
struct TransferCodingCompatibilityTests {
    @Test func americanSpellingPreservesTheStoredCancellationKey() throws {
        let legacy = Data(#"{"cancelled":{}}"#.utf8)
        #expect(try JSONDecoder().decode(TransferState.self, from: legacy) == .canceled)
        let encoded = try JSONEncoder().encode(TransferState.canceled)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["cancelled"])
        #expect(try JSONDecoder().decode(TransferState.self, from: encoded) == .canceled)
    }

    @Test func otherStoredCasesKeepTheirAssociatedValueShape() throws {
        let cases: [(String, TransferState)] = [
            (#"{"unknown":{}}"#, .unknown),
            (#"{"idle":{}}"#, .idle),
            (#"{"requested":{}}"#, .requested),
            (#"{"notRequested":{"_0":"availabilityOff"}}"#, .notRequested(.availabilityOff)),
            (#"{"inProgress":{"fractionCompleted":{"state":"known","value":0.5}}}"#,
             .inProgress(fractionCompleted: .known(0.5))),
            (#"{"failed":{"_0":{"domain":"test","code":7}}}"#,
             .failed(SourceErrorDescriptor(domain: "test", code: 7))),
            (#"{"offlineOrUnknown":{}}"#, .offlineOrUnknown(nil)),
        ]
        for (json, expected) in cases {
            let legacy = Data(json.utf8)
            #expect(try JSONDecoder().decode(TransferState.self, from: legacy) == expected)
            let encoded = try JSONEncoder().encode(expected)
            let actual = try #require(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            let original = try #require(try JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
            #expect(actual == original)
        }
    }
}
