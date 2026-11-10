import AppKit
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Review playback position", .serialized)
struct ReviewPlaybackIndicatorTests {
    private func rows(_ count: Int = 3) -> [FillerReviewRow] {
        let speaker = Speaker(name: "Host")
        return (0..<count).map { index in
            FillerReviewRow(id: UUID(), speakerID: speaker.id, speaker: speaker.name,
                phrase: "um", status: "Needs review", category: .pending,
                start: Double(index * 3 + 1), end: Double(index * 3 + 2), issue: nil, cutID: nil)
        }
    }

    @Test func positionsCoverIntervalsGapsFiltersAndUnavailableTiming() {
        let rows = rows()
        #expect(ReviewPlaybackPosition.locate(0, in: rows) == .init(row: 0, fraction: 0))
        #expect(ReviewPlaybackPosition.locate(1.5, in: rows) == .init(row: 0, fraction: 0.5))
        #expect(ReviewPlaybackPosition.locate(2, in: rows) == .init(row: 1, fraction: 0))
        #expect(ReviewPlaybackPosition.locate(3, in: rows) == .init(row: 1, fraction: 0))
        #expect(ReviewPlaybackPosition.locate(4, in: rows) == .init(row: 1, fraction: 0))
        #expect(ReviewPlaybackPosition.locate(9, in: rows) == .init(row: 2, fraction: 1))
        #expect(ReviewPlaybackPosition.locate(4.5, in: [rows[1]]) == .init(row: 0, fraction: 0.5))
        #expect(ReviewPlaybackPosition.locate(nil, in: rows) == nil)
        #expect(ReviewPlaybackPosition.locate(.nan, in: rows) == nil)
        #expect(ReviewPlaybackPosition.locate(.infinity, in: rows) == nil)
        #expect(ReviewPlaybackPosition.locate(1, in: []) == nil)
        let inactive = FillerReviewRow(id: UUID(), speakerID: rows[0].speakerID, speaker: "Host",
            phrase: "um", status: "Inactive", category: .inactive, start: 1, end: 2,
            issue: "Stale timing", cutID: nil)
        #expect(ReviewPlaybackPosition.locate(1.5, in: [inactive]) == nil)
        #expect(ReviewPlaybackPosition.locate(1.5, in: [inactive, rows[1]]) == .init(row: 1, fraction: 0))
    }

    @Test func collapsedCutsJumpPastRemovedReviewIntervals() throws {
        let rows = rows()
        let cuts = try ManualCutTimeline(cuts: [
            .init(alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000),
        ])
        let projection = AudioTimelineProjection(cuts: cuts)
        #expect(ReviewPlaybackPosition.locate(projection.originalTime(forDisplayTime: 0.5), in: rows)
            == .init(row: 0, fraction: 0))
        #expect(projection.originalTime(forDisplayTime: 1) == 2)
        #expect(ReviewPlaybackPosition.locate(projection.originalTime(forDisplayTime: 1), in: rows)
            == .init(row: 1, fraction: 0))
    }

    private struct TableHarness: View {
        let rows: [FillerReviewRow]
        let time: Double?

        var body: some View {
            Table(rows) {
                TableColumn("Phrase", value: \.phrase)
                TableColumn("Speaker", value: \.speaker)
            }
            .overlay {
                ReviewPlaybackIndicator(rows: rows, alignedTime: time).allowsHitTesting(false)
            }
        }
    }

    @Test func nativeLineUsesVirtualizedRowGeometryAndClipsOnScrollAndResize() async throws {
        let rows = rows(100)
        let host = HostedTimelineWindow(width: 760, height: 440,
            content: TableHarness(rows: rows, time: 1.5))
        defer { host.close() }
        try await host.settle()
        let table = try #require(host.descendants.compactMap { $0 as? NSTableView }.first)
        let indicator = try #require(host.descendants.compactMap {
            $0 as? ReviewPlaybackIndicator.IndicatorView
        }.first)
        let line = indicator.line
        try #require(!line.isHidden)
        let first = indicator.convert(table.rect(ofRow: 0), from: table)
        #expect(abs(line.frame.midY - first.midY) < 1)
        #expect(line.frame.height == 2)
        #expect(indicator.hitTest(.zero) == nil)
        #expect(table.selectedRow == -1)
        let clip = try #require(table.enclosingScrollView?.contentView)
        #expect(indicator.convert(clip.bounds, from: clip).contains(line.frame))
        table.scrollRowToVisible(70)
        try await host.settle()
        #expect(line.isHidden, "Offscreen playback must not draw over unrelated rows or the header.")
        let offset = clip.bounds.origin
        host.view.rootView = TableHarness(rows: rows, time: rows[70].start + 0.5)
        try await host.settle()
        try #require(!line.isHidden)
        let current = indicator.convert(table.rect(ofRow: 70), from: table)
        #expect(abs(line.frame.midY - current.midY) < 1)
        #expect(clip.bounds.origin == offset && table.selectedRow == -1)
        host.window.setContentSize(NSSize(width: 460, height: 540))
        try await host.settle()
        #expect(indicator.convert(clip.bounds, from: clip).contains(line.frame))
        try host.capture("Review playback line in scrolled native table")
        host.view.rootView = TableHarness(rows: [rows[70]], time: rows[70].start + 0.5)
        try await host.settle()
        #expect(table.numberOfRows == 1 && !line.isHidden)
        host.view.rootView = TableHarness(rows: [], time: rows[70].start)
        try await host.settle()
        #expect(line.isHidden)
        host.view.rootView = TableHarness(rows: rows, time: nil)
        try await host.settle()
        #expect(line.isHidden)
    }
}
