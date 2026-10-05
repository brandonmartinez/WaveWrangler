import Testing
@testable import WWEpisodeSetup

@Suite("Sources/Speakers split (#89)")
struct SetupSplitLayoutTests {
    @Test(arguments: [1.0, 1.25, 1.5, 1.75, 2.0])
    func speakersAlwaysGetAUsableHeightAndGrowWithTheWindow(scale: Double) {
        let minimum = SetupSplitLayout.minimumSpeakersHeight(scale: scale)
        #expect(minimum >= (44 + 28 + 4 * 24) * scale, "header + column header + four rows")
        var previous = 0.0
        for total in stride(from: 700.0 * scale, through: 2000, by: 100) {
            let split = SetupSplitLayout.heights(total: total, scale: scale, speakersFraction: SetupSplitLayout.defaultSpeakersFraction)
            #expect(split.speakers >= minimum)
            #expect(split.sources >= SetupSplitLayout.minimumSourcesHeight(scale: scale))
            #expect(split.sources + split.speakers == total)
            #expect(split.speakers >= previous, "grows with the window")
            previous = split.speakers
        }
    }

    @Test func defaultShareAndClamping() {
        let split = SetupSplitLayout.heights(total: 1000, scale: 1, speakersFraction: SetupSplitLayout.defaultSpeakersFraction)
        #expect(split.speakers == 400)
        let tiny = SetupSplitLayout.heights(total: 1000, scale: 1, speakersFraction: 0)
        #expect(tiny.speakers == SetupSplitLayout.minimumSpeakersHeight(scale: 1))
        let huge = SetupSplitLayout.heights(total: 1000, scale: 1, speakersFraction: 1)
        #expect(huge.sources == SetupSplitLayout.minimumSourcesHeight(scale: 1))
    }

    @Test func tooSmallForBothMinimumsSharesProportionally() {
        let split = SetupSplitLayout.heights(total: 200, scale: 2, speakersFraction: 0.4)
        #expect(split.sources + split.speakers == 200)
        #expect(split.speakers > 0 && split.sources > 0)
        #expect(SetupSplitLayout.heights(total: -5, scale: 1, speakersFraction: 0.4) == (0, 0))
    }

    @Test func dragFractionIsClamped() {
        #expect(SetupSplitLayout.fraction(forHandleAt: 600, total: 1000) == 0.4)
        #expect(SetupSplitLayout.fraction(forHandleAt: 0, total: 1000) == SetupSplitLayout.fractionRange.upperBound)
        #expect(SetupSplitLayout.fraction(forHandleAt: 1000, total: 1000) == SetupSplitLayout.fractionRange.lowerBound)
    }
}
