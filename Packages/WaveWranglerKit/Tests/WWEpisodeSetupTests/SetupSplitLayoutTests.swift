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
        #expect(split.speakers == 350)
        let tiny = SetupSplitLayout.heights(total: 1000, scale: 1, speakersFraction: 0)
        #expect(tiny.speakers == SetupSplitLayout.minimumSpeakersHeight(scale: 1))
        let huge = SetupSplitLayout.heights(total: 1000, scale: 1, speakersFraction: 1)
        #expect(huge.sources == SetupSplitLayout.minimumSourcesHeight(scale: 1))
    }

    @Test func tooSmallForBothMinimumsGivesSourcesPriority() {
        let split = SetupSplitLayout.heights(total: 200, scale: 2, speakersFraction: 0.4)
        #expect(split.sources + split.speakers == 200)
        #expect(split.speakers > 0 && split.sources >= split.speakers)
        // #104 default window (~460 pt for the tables at 100%): Sources keeps its six-row minimum.
        let window = SetupSplitLayout.heights(total: 420, scale: 1, speakersFraction: SetupSplitLayout.defaultSpeakersFraction)
        #expect(window.sources >= SetupSplitLayout.minimumSourcesHeight(scale: 1))
        #expect(window.speakers >= SetupSplitLayout.compactSpeakersHeight(scale: 1))
        #expect(SetupSplitLayout.heights(total: -5, scale: 1, speakersFraction: 0.4) == (0, 0))
    }

    @Test func dragFractionIsClamped() {
        #expect(SetupSplitLayout.fraction(forHandleAt: 600, total: 1000) == 0.4)
        #expect(SetupSplitLayout.fraction(forHandleAt: 0, total: 1000) == SetupSplitLayout.fractionRange.upperBound)
        #expect(SetupSplitLayout.fraction(forHandleAt: 1000, total: 1000) == SetupSplitLayout.fractionRange.lowerBound)
    }
}

@Suite("Setup default layout (#104)")
struct SetupDefaultLayoutTests {
    @Test func detailsGoBesideWhenWideAndCollapseWhenShort() {
        #expect(SetupDetailsPlacement.plan(width: 1100, height: 500, scale: 1, userExpanded: nil) == .beside(width: 300))
        // Default show window: ~500 × 500 content → collapsed, so the tables keep their rows.
        #expect(SetupDetailsPlacement.plan(width: 500, height: 500, scale: 1, userExpanded: nil) == .collapsed(barHeight: 32))
        if case .below = SetupDetailsPlacement.plan(width: 500, height: 900, scale: 1, userExpanded: nil) {} else { Issue.record("tall narrow window shows details below") }
        if case .below = SetupDetailsPlacement.plan(width: 500, height: 500, scale: 1, userExpanded: true) {} else { Issue.record("user can expand") }
        #expect(SetupDetailsPlacement.plan(width: 500, height: 900, scale: 1, userExpanded: false) == .collapsed(barHeight: 32))
        #expect(SetupDetailsPlacement.plan(width: 500, height: 500, scale: 2, userExpanded: nil) == .collapsed(barHeight: 64))
    }

    @Test func statusAlwaysShowsAndColumnsDegradeByWidth() {
        for scale in [1.0, 1.5, 2.0] {
            var previous = 0
            for width in stride(from: 200.0, through: 1600, by: 25) {
                let columns = SetupColumnPlan.columns(forWidth: width, scale: scale)
                #expect(columns.first == .name && columns.last == .status)
                #expect(columns.count >= previous, "wider never shows fewer columns")
                previous = columns.count
            }
        }
        #expect(SetupColumnPlan.columns(forWidth: 800, scale: 1) == SetupSourceColumn.allCases)
        // Default window with the workspace inspector open: ~500 pt for Setup.
        let defaultWindow = SetupColumnPlan.columns(forWidth: 500, scale: 1)
        #expect(defaultWindow.contains(.status) && defaultWindow.contains(.role) && defaultWindow.contains(.speaker))
        #expect(SetupColumnPlan.requiredWidth(defaultWindow, scale: 1) <= 500)
        let large = SetupColumnPlan.columns(forWidth: 500, scale: 2)
        #expect(large == [.name, .status])
        #expect(SetupColumnPlan.requiredWidth(large, scale: 2) <= 500)
    }

    @Test func richerSetsNeedMoreWidth() {
        for scale in [1.0, 2.0] {
            let widths = SetupColumnPlan.tiers.map { SetupColumnPlan.requiredWidth($0, scale: scale) }
            #expect(widths == widths.sorted(by: >))
        }
        #expect(SetupColumnPlan.nameWidth([.name, .status], tableWidth: 600, scale: 1) > SetupSourceColumn.nameMinimum(scale: 1))
        #expect(SetupColumnPlan.nameWidth(SetupSourceColumn.allCases, tableWidth: 100, scale: 1) == SetupSourceColumn.nameMinimum(scale: 1))
    }
}
