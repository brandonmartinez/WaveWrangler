import Foundation
import Testing
import WWCore
@testable import WWSources

@Suite("Source access model")
struct SourceAccessTests {
    @Test func availabilityDefaultsToOn() {
        #expect(SourceAvailabilitySetting.default == .on)
    }

    @Test func newObservationsStartUnknownInEveryDimension() {
        let observation = AvailabilityObservation(observedAt: Date(timeIntervalSince1970: 0))
        #expect(observation.access == .unknown)
        #expect(observation.presence == .unknown)
        #expect(observation.residency == .unknown)
        #expect(observation.transfer == .unknown)
        #expect(observation.identity == .unknown)
    }

    @Test func accessRecordRoundTripsWithoutPathIdentity() throws {
        let record = SourceAccessRecord(
            sourceID: SourceID(),
            bookmark: Data([1, 2, 3]),
            locationHint: "~/Synthetic/take.wav",
            latestObservation: AvailabilityObservation(
                observedAt: Date(timeIntervalSince1970: 10),
                access: .denied,
                transfer: .inProgress(fractionCompleted: .unknown),
                identity: .unverified
            )
        )
        let decoded = try JSONDecoder().decode(SourceAccessRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.id == record.sourceID)
    }
}
