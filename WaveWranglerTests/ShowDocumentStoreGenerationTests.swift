import Foundation
import Testing
import WWCore

@Suite("Show document mutation generation")
struct ShowDocumentStoreGenerationTests {
    private func model(_ title: String) -> ShowDocumentModel {
        ShowDocumentModel(show: Show(title: title))
    }

    @Test func switchingAwayAndBackDoesNotRestoreAnOldGeneration() throws {
        let original = model("Original")
        var live = original
        var generation = DocumentMutationGeneration()
        let captured = try #require(generation.current)

        live = model("Other")
        generation.advance()
        live = original
        generation.advance()

        #expect(SharedModelPublication.decide(live: live, expected: original) == .publish)
        #expect(!generation.matches(captured), "equal models after ABA must not restore authority")
        #expect(generation.current == 2)
    }

    @Test func everyMutationPathAdvancesAndNoOpDoesNot() throws {
        let source = try UITestHooksDebugOnlyTests.source("Document/ShowDocumentStore.swift")
        let loaded = try #require(source.range(of: "func replaceLoadedModel("))
        let apply = try #require(source.range(of: "func apply("))
        let replacement = try #require(source.range(of: "private func replace("))
        let loadedBody = source[loaded.lowerBound..<apply.lowerBound]
        let applyBody = source[apply.lowerBound..<replacement.lowerBound]
        let replacementBody = source[replacement.lowerBound...]

        #expect(loadedBody.contains("self.model = model\n        advanceMutationGeneration()"))
        #expect(applyBody.contains("guard updated != model else { return true }"))
        #expect(applyBody.contains("model = updated\n                advanceMutationGeneration()"))
        #expect(replacementBody.contains("model = newModel\n        advanceMutationGeneration()"))
        #expect(replacementBody.contains("store.replace(with: previous, actionName: actionName, afterChange: afterChange)"),
                "undo and redo must recurse through the same advancing replacement")
        #expect(source.contains("func captureMutationGeneration() -> UInt64? {\n        mutationGeneration.current"))
        #expect(source.contains("mutationGeneration.matches(expected)"))
    }

    @Test func coalescingReloadAndUndoRedoNeverReuseARevision() throws {
        var generation = DocumentMutationGeneration()
        let captured = try #require(generation.current)
        generation.advance()
        let first = generation.current
        generation.advance()
        #expect(first != generation.current)
        generation.advance()
        generation.advance()
        generation.advance()
        generation.advance()
        #expect(generation.current == 6)
        #expect(!generation.matches(captured))
    }

    @Test func exhaustionRefusesForeverWithoutWrapping() throws {
        var generation = DocumentMutationGeneration(initial: UInt64.max - 1)
        generation.advance()
        #expect(generation.current == UInt64.max)
        let last = try #require(generation.current)
        generation.advance()
        #expect(generation.current == nil)
        #expect(!generation.matches(last))
        generation.advance()
        #expect(generation.current == nil)
        #expect(!generation.matches(0))
    }
}
