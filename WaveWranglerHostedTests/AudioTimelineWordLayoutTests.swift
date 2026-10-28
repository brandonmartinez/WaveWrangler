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

    @Test func repeatedPlayheadUpdatesReuseTheExactViewportLayout() {
        let words = (0..<30_000).map { word("word\($0)", Double($0) * 0.4, Double($0) * 0.4 + 0.3) }
        let index = AudioTimelineWordIndex(words: words)
        let cache = AudioTimelineWordLayoutCache(index: index)
        let expected = AudioTimelineWordLayout.make(index: index, start: 0, duration: 12_000, width: 1400)
        for _ in 0..<1_000 {
            #expect(cache.layout(start: 0, duration: 12_000, width: 1400) == expected)
        }
        #expect(cache.preparationCount == 1, "Playhead/selection-only renders must not rebuild transcript geometry.")
    }

    @Test func viewportAndUncertaintyChangesInvalidateGeometryButNotTheWordIndex() {
        let words = [word("left", 0, 1), word("right", 2, 3)]
        let index = AudioTimelineWordIndex(words: words)
        let cache = AudioTimelineWordLayoutCache(index: index)
        for (start, duration, width, uncertain) in [
            (0.0, 4.0, 600.0, Set<UUID>()),
            (1.0, 4.0, 600.0, Set<UUID>()),
            (1.0, 2.0, 600.0, Set<UUID>()),
            (1.0, 2.0, 1200.0, Set<UUID>()),
            (1.0, 2.0, 1200.0, Set([words[1].id])),
        ] {
            let layout = cache.layout(start: start, duration: duration, width: width, uncertainWordIDs: uncertain)
            #expect(layout == AudioTimelineWordLayout.make(index: index, start: start, duration: duration,
                width: width, uncertainWordIDs: uncertain))
        }
        #expect(cache.preparationCount == 5)
        #expect(index.words == words)
    }

    @Test func replacementWordsCutsAndSourceBoundsUseIndependentLayoutCaches() throws {
        let original = [word("before", 0, 1), word("after", 2, 3)]
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 0, endFrame: 48_000)
        ])
        for index in [
            AudioTimelineWordIndex(words: original),
            AudioTimelineWordIndex(words: original, cuts: cuts),
            AudioTimelineWordIndex(words: original, sourceBounds: 1...4),
            AudioTimelineWordIndex(words: [word("replacement", 1, 2)]),
        ] {
            let cache = AudioTimelineWordLayoutCache(index: index)
            #expect(cache.layout(start: 0, duration: 4, width: 600)
                == AudioTimelineWordLayout.make(index: index, start: 0, duration: 4, width: 600))
            #expect(cache.preparationCount == 1)
        }
    }

    @Test func acceptedAdaptiveMarkerIdentityContainsOnlyTimingAndViewportInputs() throws {
        let segment = SourceTimingSegment(sourceStart: 10, sourceEnd: 20, alignedStart: 12,
            rateRatio: 1, kind: .estimated)
        let markers = AcceptedAdaptiveTimingMarkers(segments: [segment], start: 10, duration: 10,
            size: CGSize(width: 600, height: 100))
        #expect(markers.position(for: segment) == 120)
        #expect(markers == AcceptedAdaptiveTimingMarkers(segments: [segment], start: 10, duration: 10,
            size: CGSize(width: 600, height: 100)))
        #expect(markers != AcceptedAdaptiveTimingMarkers(segments: [segment], start: 11, duration: 10,
            size: markers.size))
        #expect(markers != AcceptedAdaptiveTimingMarkers(segments: [segment], start: 10, duration: 5,
            size: markers.size))
        #expect(markers != AcceptedAdaptiveTimingMarkers(segments: [segment], start: 10, duration: 10,
            size: CGSize(width: 1200, height: 100)))
        var changed = segment
        changed.kind = .anchorGuided
        #expect(markers != AcceptedAdaptiveTimingMarkers(segments: [changed], start: 10, duration: 10,
            size: markers.size))
        changed.alignedStart = 9
        #expect(markers.position(for: changed) == nil)
        changed.alignedStart = 20
        #expect(markers.position(for: changed) == 600)
        changed.alignedStart = 20.001
        #expect(markers.position(for: changed) == nil)
    }

    @Test func indexedQueriesMatchScanningWithOverlapsCutsAndStableTies() throws {
        let long = word("overlap", 0, 100)
        let a = word("first", 50, 51), b = word("second", 50, 51)
        let removed = word("removed", 10, 11)
        let words = [b, long, a, removed, word("later", 120, 121)]
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 10 * 48_000, endFrame: 11 * 48_000)
        ])
        let index = AudioTimelineWordIndex(words: words, cuts: cuts)
        #expect(index.words.map(\.id) == [long.id, b.id, a.id, words[4].id])
        #expect(index.visible(start: 49.5, end: 49.6).map(\.id) == [long.id, b.id, a.id])
        #expect(index.visible(start: 90, end: 91).map(\.id) == [long.id],
                "Binary lookup must retain long overlapping words that begin before the viewport")
        #expect(index.visible(start: 99, end: 119).isEmpty)
        #expect(index.visible(start: 119, end: 120).map(\.id) == [words[4].id])
    }

    @Test func workingRangeFiltersOriginalWordsBeforeCutProjection() throws {
        let crossing = word("crossing", 10.5, 11.5), inside = word("inside", 12, 12.5)
        let words = [word("before", 9, 11), crossing, inside, word("after", 13, 14)]
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 10 * 48_000, endFrame: 11 * 48_000)
        ])
        let index = AudioTimelineWordIndex(words: words, cuts: cuts, sourceBounds: 11...13)
        #expect(index.words.map(\.id) == [crossing.id, inside.id])
        #expect(index.visible(start: 10, end: 12).map(\.id) == [crossing.id, inside.id])
        #expect(index.words.first?.alignedStart == 10)
    }

    @Test func repeatedEpisodePansUseAnIndexInsteadOfScanningTheEntireTranscript() {
        let words = (0..<30_000).map { word("word\($0)", Double($0) * 0.4, Double($0) * 0.4 + 0.3) }
        let index = AudioTimelineWordIndex(words: words)
        let clock = ContinuousClock()
        var scanned: [[UUID]] = []
        let beforeScan = clock.now
        for position in 0..<100 {
            let start = Double(position) * 50
            scanned.append(words.filter {
                ($0.alignedEnd ?? 0) > start && ($0.alignedStart ?? .infinity) < start + 5
            }.map(\.id))
        }
        let scanDuration = beforeScan.duration(to: clock.now)
        let beforeIndex = clock.now
        var indexed: [[UUID]] = []
        for position in 0..<100 {
            indexed.append(index.visible(start: Double(position) * 50, end: Double(position) * 50 + 5).map(\.id))
        }
        let indexDuration = beforeIndex.duration(to: clock.now)
        #expect(indexed == scanned)
        #expect(indexDuration < scanDuration / 4,
                "Indexed viewport selection must be at least four times faster than whole-episode scanning")
        print("TIMELINE_WORD_INDEX words=30000 pans=100 scan=\(scanDuration) indexed=\(indexDuration)")
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
        #expect(layout.height == 24)
    }

    @Test func collisionAvoidanceNeverMovesAWordAwayFromItsTrueAudioPosition() {
        let layout = AudioTimelineWordLayout.make(words: [
            word("first", 0, 0.001), word("second", 0.01, 0.011),
            word("third", 0.02, 0.021), word("fourth", 0.03, 0.031),
        ], start: 0, duration: 10, width: 600)
        #expect(layout.detail == .hidden && layout.placements.isEmpty)
        #expect(layout.wordCount == 4, "Crowded recognition is hidden, not staggered or moved.")
        #expect(layout.height == 24)
    }

    @Test func invalidGeometryIsNotProjected() {
        let words = [word("hello", 0, 1)]
        for width in [0.0, -Double.infinity, Double.nan] {
            #expect(AudioTimelineWordLayout.make(words: words, start: 0, duration: 1, width: width).placements.isEmpty)
        }
        #expect(AudioTimelineWordLayout.make(words: words, start: .nan, duration: 1, width: 600).placements.isEmpty)
        #expect(AudioTimelineWordLayout.make(words: words, start: 0, duration: 0, width: 600).placements.isEmpty)
    }

    @Test func progressiveUnitsKeepRealWordsAndStableHeightAtEveryScale() throws {
        let words = (0..<30).map { word("word\($0)\($0 % 10 == 9 ? "." : "")", Double($0), Double($0) + 0.8) }
        let layouts = [0.1, 10.0, 30.0, 80.0, 120.0].map { pixelsPerSecond in
            AudioTimelineWordLayout.make(words: words, start: 0, duration: 30, width: pixelsPerSecond * 30)
        }
        #expect(layouts.map(\.detail) == [.hidden, .sentence, .phrase, .word, .timing])
        #expect(layouts.allSatisfy { $0.height == 24 })
        for layout in layouts.dropFirst() {
            #expect(layout.placements.flatMap(\.words) == words)
            #expect(layout.placements.allSatisfy { $0.row == 0 })
            for pair in zip(layout.placements, layout.placements.dropFirst()) {
                #expect(pair.0.x + pair.0.width <= pair.1.x)
            }
        }
        #expect(AudioTimelineWordLayout.abbreviated(["the", "long", "sentence", "ends", "here"], capacity: 15) == "the long … here")
        #expect(words.map(\.text).joined(separator: " ").contains("word29."))
    }

    @Test(arguments: [120.0, 240.0])
    func touchingWordIntervalsStaySeparateAtWordAndMarkerZoom(_ pixelsPerSecond: Double) {
        let words = (0..<10).map { word("word\($0)", Double($0) / 2, Double($0 + 1) / 2) }
        let layout = AudioTimelineWordLayout.make(words: words, start: 0, duration: 5,
                                                width: pixelsPerSecond * 5)
        #expect(layout.detail == (pixelsPerSecond == 120 ? .word : .timing))
        #expect(layout.placements.count == words.count,
                "Collision handling must never merge adjoining words back into a sentence.")
        #expect(layout.placements.map(\.words) == words.map { [$0] })
        #expect(layout.placements.map(\.text) == words.map(\.text))
        #expect(layout.placements.map(\.x) == words.indices.map { Double($0) / 2 * pixelsPerSecond })
        #expect(layout.placements.allSatisfy { $0.width == pixelsPerSecond / 2 })
    }

    @Test func sentenceAndPhraseUnitsRemainDistinctWithoutSilenceBetweenWords() {
        let words = (0..<20).map {
            word("word\($0)\($0 % 10 == 9 ? "." : "")", Double($0) / 2, Double($0 + 1) / 2)
        }
        let sentences = AudioTimelineWordLayout.make(words: words, start: 0, duration: 10, width: 200)
        let phrases = AudioTimelineWordLayout.make(words: words, start: 0, duration: 10, width: 600)
        #expect(sentences.detail == .sentence && sentences.placements.map(\.words.count) == [10, 10])
        #expect(phrases.detail == .phrase && phrases.placements.map(\.words.count) == [5, 5, 5, 5])
        #expect(sentences.placements.flatMap(\.words) == words)
        #expect(phrases.placements.flatMap(\.words) == words)
    }

    @Test func wideZoomHidesSparseSpeechAndPausesDoNotInflateWordDetail() {
        let words = [word("hello", 2, 2.5), word("again", 500, 500.5)]
        let wide = AudioTimelineWordLayout.make(words: words, start: 0, duration: 600, width: 600)
        #expect(wide.detail == .hidden && wide.placements.isEmpty)
        let all = AudioTimelineWordLayout.make(words: words, start: 0, duration: 600, width: 12_000)
        let panned = AudioTimelineWordLayout.make(words: words, start: 490, duration: 30, width: 600)
        #expect(all.detail == .sentence && panned.detail == .sentence,
                "The same zoom uses speech duration, not silence or the number of visible words.")
    }

    @Test func overlappingRecognitionClipsLabelsWithoutMergingOrRetimingWords() {
        let words = [word("first", 0, 1), word("second", 0.75, 1.5)]
        let layout = AudioTimelineWordLayout.make(words: words, start: 0, duration: 2, width: 600)
        #expect(layout.detail == .timing)
        #expect(layout.placements.map(\.words) == words.map { [$0] })
        #expect(layout.placements.map(\.x) == [0, 225])
        #expect(layout.placements.map(\.width) == [300, 225])
        #expect(layout.placements.map(\.labelWidth) == [225, 225])
        #expect(words[0].alignedEnd == 1 && words[1].alignedStart == 0.75)
    }

    @Test func markerDetailCollapsesOnlyPresentation() {
        #expect(FillerMarkerDetail.make(width: 60) == .boundaries)
        #expect(FillerMarkerDetail.make(width: 20) == .pole)
        #expect(FillerMarkerDetail.make(width: 2) == .dot)
        #expect(FillerMarkerDetail.make(width: 20, neighborDistance: 10) == .dot)
    }

    @Test func boundaryStrokesAppearOnlyAtTheClosestTranscriptDetail() async throws {
        let words = [word("first", 1, 1.5), word("second", 1.5, 2)]
        for duration in [5.0, 2.5, 0.5] {
            let start = duration == 0.5 ? 1.25 : 0
            let layout = AudioTimelineWordLayout.make(words: words, start: start, duration: duration, width: 600)
            #expect(layout.detail == (duration == 5 ? .word : .timing))
            let renderer = ImageRenderer(content: AudioTimelineWords(
                words: words, start: start, duration: duration, selectedWord: nil,
                select: { _ in }, zoom: { _ in })
                .frame(width: 600, height: 72, alignment: .topLeading)
                .background(Color.white).environment(\.colorScheme, .light))
            renderer.scale = 1
            _ = try #require(renderer.cgImage)
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            for item in layout.placements {
                let boundaries = [
                    (Int(item.x), (item.words.first?.alignedStart ?? start) >= start),
                    (Int(item.x + item.width) - 1, (item.words.last?.alignedEnd ?? start + duration) <= start + duration),
                ]
                for (x, isRealBoundary) in boundaries {
                    var hasBoundary = false
                    for y in 4..<18 {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                            hasBoundary = true
                        }
                    }
                    #expect(hasBoundary == (layout.detail == .timing && isRealBoundary),
                            "Draw real recognition boundaries, never artificial markers at viewport edges.")
                }
            }
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                              named: "Transcript \(layout.detail.title) at \(start).png")
        }
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
