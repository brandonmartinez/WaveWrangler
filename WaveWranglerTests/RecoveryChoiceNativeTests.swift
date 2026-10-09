import Foundation
import Testing

@Suite("Recovery presenter source boundary")
struct RecoveryChoiceNativeTests {
    @Test func allRecoveryPresentersConsumeTheSharedPlanInsteadOfIndependentOrdering() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sites: [(String, String, String, String)] = [
            ("Packages/WaveWranglerKit/Sources/WWPersistence/DocumentOpener.swift",
             "public func candidates(", "\n    }\n}", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "func refreshEditCheckpointOffer()", "var selectedEditCheckpointCandidate:", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "func refreshPriorCheckpoints()", "func openPriorAsCopy(", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "static func error(", "final class RecoveryAttempter:", "RecoveryChoicePresentation.plan("),
            ("Packages/WaveWranglerKit/Sources/WWOrganizer/EditCheckpointOffer.swift",
             "public init(", "public static func confirmation(", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/EditCheckpointOfferBridge.swift",
             "var editCheckpointOfferState:", "func selectedEditCheckpointForDiscard()", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/ShowWorkspaceView.swift",
             "private struct ShowMessageBar:", "// MARK: - Window binding", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/MessageBar.swift",
             "var body: some View", "\n    }\n}", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/WorkspaceToolbar.swift",
             "private struct SaveStatusPopover:", "private struct PopoverAccessibilityLabel:", "RecoveryChoicePresentation"),
            ("WaveWrangler/Commands/OpaqueErrorPanel.swift",
             "private func buildContent()", "private static func label(", "RecoveryChoicePresentation"),
        ]
        for (path, start, end, required) in sites {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            let begin = try #require(source.range(of: start), "\(path) lost \(start)")
            let finish = try #require(source.range(of: end, range: begin.upperBound..<source.endIndex), "\(path) lost \(end)")
            let presenter = source[begin.lowerBound..<finish.lowerBound]
            #expect(presenter.contains(required), "\(path): \(start) bypasses the shared recovery plan")
        }
    }
}
