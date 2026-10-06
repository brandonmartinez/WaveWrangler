import Foundation
import Testing
@testable import WWOrganizer

/// #140: the entry list's column plan keeps Status visible at the default Library window and at 200% text, and
/// never produces a non-finite width (#129).
@Suite("Library entry column plan")
struct LibraryEntryColumnPlanTests {
    /// The entry outline's width in the default 1000×600 Library window (measured: 520 pt).
    static let defaultWidth = 520.0

    @Test func defaultWindowShowsStatusAndFits() {
        let plan = LibraryEntryColumnPlan.plan(availableWidth: Self.defaultWidth, scale: 1)
        #expect(plan.visible == [.name, .location, .status])
        #expect(plan.hidden == [.episodes, .lastOpened])
        #expect(total(plan) <= Self.defaultWidth)
        #expect(plan.widths[.name]! >= LibraryEntryColumnKind.name.baseWidth, "Name at or above its minimum")
        #expect(plan.widths[.status] == LibraryEntryColumnKind.status.baseWidth)
    }

    @Test func wideWindowShowsEveryColumnAndGivesNameTheRest() {
        let plan = LibraryEntryColumnPlan.plan(availableWidth: 1200, scale: 1)
        #expect(plan.visible == LibraryEntryColumnKind.allCases)
        #expect(total(plan) == 1200 || abs(total(plan) - 1200) < 1)
    }

    @Test func twoHundredPercentTextKeepsStatusAtFullWidth() {
        let plan = LibraryEntryColumnPlan.plan(availableWidth: Self.defaultWidth, scale: 2)
        #expect(plan.visible == [.name, .status])
        #expect(plan.widths[.status] == LibraryEntryColumnKind.status.baseWidth * 2)
        #expect(total(plan) <= Self.defaultWidth, "Status isn't pushed out of view")
        #expect(plan.widths[.name]! >= 120, "Name keeps a usable width")
    }

    @Test func columnsHideInPriorityOrderAsWidthShrinks() {
        var previous = LibraryEntryColumnKind.allCases.count
        var hiddenOrder: [LibraryEntryColumnKind] = []
        for width in stride(from: 1400.0, through: 200, by: -5) {
            for scale in [1.0] {
                let plan = LibraryEntryColumnPlan.plan(availableWidth: width, scale: scale)
                #expect(plan.visible.count <= previous, "never more columns at a narrower width")
                #expect(plan.visible.contains(.status) && plan.visible.contains(.name))
                for column in plan.hidden where !hiddenOrder.contains(column) { hiddenOrder.append(column) }
                previous = plan.visible.count
            }
        }
        #expect(hiddenOrder == [.episodes, .lastOpened, .location])
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -50, 1e-9])
    func degenerateWidthsGiveFiniteWidths(_ width: Double) {
        for scale in [Double.nan, 0, 1, 2, .infinity] {
            let plan = LibraryEntryColumnPlan.plan(availableWidth: width, scale: scale)
            #expect(plan.visible.contains(.status))
            #expect(plan.widths.values.allSatisfy { $0.isFinite && $0 > 0 }, "\(plan.widths)")
        }
    }

    @Test func everyWidthIsFiniteAndPositiveAcrossSizes() {
        for width in stride(from: 0.0, through: 3000, by: 37) {
            for scale in [1.0, 1.25, 1.5, 1.75, 2.0] {
                let plan = LibraryEntryColumnPlan.plan(availableWidth: width, scale: scale)
                #expect(plan.widths.values.allSatisfy { $0.isFinite && $0 > 0 })
                #expect(plan.widths[.status] == (LibraryEntryColumnKind.status.baseWidth * scale).rounded())
            }
        }
    }

    private func total(_ plan: LibraryEntryColumnPlan.Plan) -> Double {
        plan.widths.values.reduce(0, +) + LibraryEntryColumnPlan.fixedOverhead + LibraryEntryColumnPlan.spacing * Double(plan.visible.count - 1)
    }
}
