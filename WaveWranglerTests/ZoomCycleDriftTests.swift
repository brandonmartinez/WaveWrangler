import Testing

@Suite("Zoom cycle drift")
struct ZoomCycleDriftTests {
    @Test func rejectsCompoundingOffsets() {
        let samples = (1...10).map {
            ZoomCycleSample(cycle: $0, offset: 900 + Double($0 - 1) * 5, tableWidth: 1_101, tier: "all-columns")
        }

        let result = checkZoomCycleDrift(samples)

        #expect(!result.passes)
        #expect(result.maximumAbsoluteSlope > 1)
        #expect(result.maximumAbsoluteMedianShift > 10)
    }

    @Test func acceptsRecordedLayoutSwitches() {
        let shardB = [895.0, 922.5, 907.0, 911.5, 915.0, 915.5, 917.0, 917.0, 960.0, 962.0]
        let isolatedRerun = [905.5, 910.0, 914.0, 939.5, 914.5, 916.5, 916.5, 912.5, 913.5, 974.5]

        for offsets in [shardB, isolatedRerun] {
            let samples = offsets.enumerated().map {
                ZoomCycleSample(cycle: $0.offset + 1, offset: $0.element, tableWidth: 1_101, tier: "all-columns")
            }
            let result = checkZoomCycleDrift(samples)

            #expect(result.passes, "unexpected drift violations: \(result.violations)")
            #expect(result.modeCount > 1, "recorded trace should expose its stable layout switches")
        }
    }
}
