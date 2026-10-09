import Foundation
import Testing
@testable import WWCore

@Suite("Shared recovery choice presentation")
struct RecoveryChoicePresentationTests {
    private let a = "00000000-0000-0000-0000-000000000001"
    private let b = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"

    private func record(
        _ id: String, _ kind: RecoveryChoicePresentation.Kind, show: String,
        saved: TimeInterval? = nil, created: TimeInterval? = nil, revision: Int? = nil,
        disposition: RecoveryChoicePresentation.Disposition = .open
    ) -> RecoveryChoicePresentation.Record {
        .init(recordID: id, kind: kind, documentID: show,
              savedAt: saved.map(Date.init(timeIntervalSince1970:)),
              createdAt: created.map(Date.init(timeIntervalSince1970:)),
              revision: revision, disposition: disposition)
    }

    @Test func reversedUUIDsAndInputOrderNeverStandInForChronology() {
        let records = [
            record("a-draft", .unsavedCheckpoint, show: a, created: 1_700_000_100, revision: 2),
            record("a-prior", .savedPrior, show: a, saved: 1_700_000_000, revision: 1),
            record("b-draft", .unsavedCheckpoint, show: b, created: 1_700_000_300, revision: 2),
            record("b-prior", .savedPrior, show: b, saved: 1_700_000_200, revision: 1),
        ]
        for input in [records, Array(records.reversed())] {
            let plan = RecoveryChoicePresentation.plan(records: input)
            #expect(plan.choices.map(\.record.recordID) == ["b-draft", "b-prior", "a-draft", "a-prior"])
            #expect(plan.choices.first?.label.contains(b) == true)
            #expect(plan.choices.first?.label.contains("Created") == true)
            #expect(plan.choices[1].label.contains("Saved") && !plan.choices[1].label.contains("Created"))
            #expect(plan.choices[2].label.contains(a))
            #expect(plan.defaultRecordID == nil, "cross-show recovery must require an explicit identity-bound choice")
        }
    }

    @Test func tiedOrMissingProvenanceIsNeverANewestOrReturnDefault() {
        let date = 1_700_000_000.0
        for records in [
            [record("a", .savedPrior, show: a, revision: 1),
             record("b", .savedPrior, show: b, saved: date, revision: 2)],
            [record("a", .savedPrior, show: a, saved: date, revision: 1),
             record("b", .savedPrior, show: b, saved: date, revision: 2)],
            [record("a", .unsavedCheckpoint, show: a, revision: 1),
             record("b", .unsavedCheckpoint, show: b, created: date, revision: 1)],
            [record("a", .unsavedCheckpoint, show: a, created: date, revision: 1),
             record("b", .unsavedCheckpoint, show: b, created: date, revision: 1)],
        ] {
            let plan = RecoveryChoicePresentation.plan(records: records)
            #expect(plan.choices.count == 2)
            #expect(plan.defaultRecordID == nil)
            #expect(!plan.choices.map(\.label).joined().contains("Newest"))
            #expect(plan.choices.allSatisfy { $0.label.contains($0.record.documentID) })
            #expect(Set(plan.choices.map(\.record.recordID)) == Set(["a", "b"]))
            for choice in plan.choices {
                #expect(choice.label.contains(choice.record.kind == .unsavedCheckpoint ? "Created" : "Saved"))
                if choice.record.savedAt == nil && choice.record.createdAt == nil {
                    #expect(choice.label.contains("date unknown"))
                }
            }
        }
    }

    @Test func rawDamagedAndOlderSchemaCopiesKeepTheirOwnIdentityAndRevealRoute() {
        let plan = RecoveryChoicePresentation.plan(records: [
            record("raw-damaged-prior", .damagedSaved, show: a, revision: 2, disposition: .reveal),
            record("raw-damaged-draft", .damagedUnsaved, show: b, revision: 3, disposition: .reveal),
            record("raw-older-schema", .olderSchema, show: a, saved: 1_700_000_010,
                   revision: 1, disposition: .reveal),
        ])
        #expect(Set(plan.choices.map(\.record.recordID)) ==
                Set(["raw-damaged-prior", "raw-damaged-draft", "raw-older-schema"]))
        #expect(plan.choices.allSatisfy { $0.record.disposition == .reveal && $0.label.contains($0.record.documentID) })
        #expect(plan.choices.allSatisfy { $0.label.contains("Show in Finder") && !$0.label.contains("Open Copy") })
        #expect(plan.choices.first { $0.record.recordID == "raw-older-schema" }?.label.contains("Saved") == true)
        #expect(plan.defaultRecordID == nil)
    }

    @Test func moreThanNineCopiesHaveNoHiddenOrDuplicateActiveKeyboardChoices() {
        let records = (0..<12).map {
            record("draft-\($0)", .unsavedCheckpoint, show: $0.isMultiple(of: 2) ? a : b,
                   created: TimeInterval(1_700_000_000 + $0), revision: $0)
        }
        let plan = RecoveryChoicePresentation.plan(records: records)
        #expect(plan.choices.count == 12)
        #expect(plan.pages.count == 2)
        #expect(plan.pages.flatMap(\.choices).map(\.record.recordID) == plan.choices.map(\.record.recordID))
        guard plan.pages.count == 2 else { return }
        for page in plan.pages {
            #expect(page.choices.count <= 9)
            #expect(page.choices.map(\.shortcut) ==
                    page.choices.indices.map { "⌘\($0 + 1)" })
            #expect(Set(page.choices.map(\.shortcut)).count == page.choices.count)
            #expect(page.choices.allSatisfy { $0.label.contains($0.shortcut) })
        }
        #expect(plan.pages[0].nextShortcut == "⌘]")
        #expect(plan.pages[1].previousShortcut == "⌘[")
        #expect(plan.pages[0].previousShortcut == nil && plan.pages[1].nextShortcut == nil)
        #expect(plan.defaultRecordID == nil)
    }
}
