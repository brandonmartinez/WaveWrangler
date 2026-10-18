import AppKit
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Transcript positions on the shared audio timeline")
struct AudioTimelineWordLayoutTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, sourceStartFrame: 0, sourceEndFrame: 100,
                       alignedStart: start, alignedEnd: end)
    }

    @Test func wordsUseExactWaveformTimeCoordinatesAndCompactRows() {
        let a = word("hello", 12, 13), b = word("there", 16, 18)
        let layout = AudioTimelineWordLayout.make(words: [b, a], start: 10, duration: 10, width: 600)
        #expect(layout.placements.map(\.word.id) == [a.id, b.id])
        #expect(layout.placements.map(\.x) == [120, 360])
        #expect(layout.placements.map(\.width) == [60, 120])
        #expect(layout.placements.allSatisfy { $0.row == 0 && $0.showsLabel })
        #expect(layout.height == 24 && !layout.isDense)
        let panned = AudioTimelineWordLayout.make(words: [a], start: 11, duration: 10, width: 600)
        let zoomed = AudioTimelineWordLayout.make(words: [a], start: 11, duration: 5, width: 600)
        #expect(panned.placements.first?.x == 60 && panned.placements.first?.width == 60)
        #expect(zoomed.placements.first?.x == 120 && zoomed.placements.first?.width == 120)
        #expect(a.alignedStart == 12 && a.sourceStartFrame == 0)
    }

    @Test func clipsAtViewportEdgesAndNeverInventsTimingForUntimedWords() {
        let layout = AudioTimelineWordLayout.make(words: [
            word("left", 9, 11), word("right", 19, 21), word("outside", 25, 26),
            TranscriptWord(text: "untimed"), word("invalid", .nan, 13),
        ], start: 10, duration: 10, width: 600)
        #expect(layout.placements.map(\.x) == [0, 540])
        #expect(layout.placements.map(\.width) == [60, 60])
        #expect(layout.wordCount == 2)
    }

    @Test func denseSpeechUsesBoundedGraphicalCoverageNotThousandsOfOverlappingButtons() {
        let words = (0..<1_500).map { word("um", Double($0) / 50, Double($0 + 1) / 50) }
        let layout = AudioTimelineWordLayout.make(words: words, start: 0, duration: 30, width: 600)
        #expect(layout.isDense && layout.placements.isEmpty && layout.wordCount == 1_500)
        #expect(layout.densityRanges.count <= 600)
        #expect(layout.densityRanges.first?.lowerBound == 0)
        #expect(layout.densityRanges.last?.upperBound == 600)
        #expect(layout.height == 28)
    }

    @Test func collisionAvoidanceNeverMovesAWordAwayFromItsTrueAudioPosition() {
        let layout = AudioTimelineWordLayout.make(words: [
            word("first", 0, 0.001), word("second", 0.01, 0.011),
            word("third", 0.02, 0.021), word("fourth", 0.03, 0.031),
        ], start: 0, duration: 10, width: 600)
        #expect(layout.placements.map(\.row).prefix(3) == [0, 1, 2])
        for (item, expected) in zip(layout.placements, [0, 0.6, 1.2, 1.8]) {
            #expect(abs(item.x - expected) < 0.000_001)
            #expect(item.width < 0.061, "A readable label must not fabricate a longer word interval")
        }
        #expect(layout.placements.last?.showsLabel == false)
        #expect(layout.height == 72)
    }

    @Test func invalidGeometryIsNotProjected() {
        let words = [word("hello", 0, 1)]
        for width in [0.0, -Double.infinity, Double.nan] {
            #expect(AudioTimelineWordLayout.make(words: words, start: 0, duration: 1, width: width).placements.isEmpty)
        }
        #expect(AudioTimelineWordLayout.make(words: words, start: .nan, duration: 1, width: 600).placements.isEmpty)
        #expect(AudioTimelineWordLayout.make(words: words, start: 0, duration: 0, width: 600).placements.isEmpty)
    }

    @Test func uncertainCoverageDoesNotMoveOrHideRawWordsAtEitherScale() {
        let a = word("no,", 12, 13), b = word("hello", 16, 18)
        let ordinary = AudioTimelineWordLayout.make(words: [a, b], start: 10, duration: 10, width: 600)
        let reviewed = AudioTimelineWordLayout.make(words: [a, b], start: 10, duration: 10, width: 600,
            uncertainWordIDs: [a.id])
        #expect(reviewed.placements.map(\.word) == [a, b])
        #expect(reviewed.placements.map(\.x) == ordinary.placements.map(\.x))
        #expect(reviewed.placements.map(\.width) == ordinary.placements.map(\.width))
        #expect(reviewed.uncertainRanges == [120..<180])
        let denseWords = (0..<1_500).map { word("no,", Double($0) / 50, Double($0 + 1) / 50) }
        let dense = AudioTimelineWordLayout.make(words: denseWords, start: 0, duration: 30, width: 600,
            uncertainWordIDs: Set(denseWords.prefix(500).map(\.id)))
        #expect(dense.isDense && dense.wordCount == 1_500)
        #expect(dense.uncertainRanges == [0..<200])
        #expect(dense.densityRanges == [0..<600])
    }

    @Test func suspectWordActuallyRendersInAmberWhileKeepingItsOriginalLabel() async throws {
        let suspect = word("no,", 12, 13), ordinary = word("hello", 16, 18)
        let renderer = ImageRenderer(content: AudioTimelineWords(
            words: [suspect, ordinary], start: 10, duration: 10, selectedWord: nil,
            select: { _ in }, zoom: { _ in }, uncertainWordIDs: [suspect.id])
            .frame(width: 600, height: 72).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 1
        _ = try #require(renderer.cgImage)
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func hasAmber(at x: Int) throws -> Bool {
            for y in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > color.greenComponent + 0.03
                    && color.greenComponent > color.blueComponent + 0.03 { return true }
            }
            return false
        }
        #expect(try hasAmber(at: 125))
        #expect(try !hasAmber(at: 365))
        #expect(suspect.text == "no," && suspect.alignedStart == 12 && suspect.alignedEnd == 13)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                          named: "Uncertain raw word stays at its original aligned position.png")
    }

    @Test(arguments: [
        (10.0, 10.0, 125, 365, 300),
        (11.0, 10.0, 65, 305, 250),
        (11.0, 8.0, 80, 380, 300),
    ])
    func renderedWordsAreNotClippedToTheLongestWordWidth(
        _ start: Double, _ duration: Double, _ firstColumn: Int, _ laterColumn: Int, _ gapColumn: Int
    ) async throws {
        let renderer = ImageRenderer(content: AudioTimelineWords(
            words: [word("hello", 12, 13), word("there", 16, 18)],
            start: start, duration: duration, selectedWord: nil, select: { _ in }, zoom: { _ in })
            .frame(width: 600, height: 72, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        _ = try #require(renderer.cgImage)
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func hasInk(at x: Int) throws -> Bool {
            for y in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.96 { return true }
            }
            return false
        }
        #expect(try hasInk(at: firstColumn), "The first word renders at its actual aligned position")
        #expect(try hasInk(at: laterColumn), "The later word remains visible across the full lane")
        #expect(try !hasInk(at: gapColumn), "The untimed space between words stays empty")
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                          named: "Timed words at \(start) for \(duration) seconds.png")
    }
}
