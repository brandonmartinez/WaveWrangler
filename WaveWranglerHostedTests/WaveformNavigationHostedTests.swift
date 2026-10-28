import AppKit
import SwiftUI
import Testing
import WWAlignPipeline
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Waveform navigation and rendered silhouettes", .serialized)
struct WaveformNavigationHostedTests {
    @Test func zoomReturnsToThePlayheadAfterPanningWithoutSeekingOrEditing() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        let original = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        try #require(f.model.previewWaveformPlayhead(to: 2))
        f.model.waveformStartSeconds = 18
        f.model.waveformDurationSeconds = 8
        try #require(f.model.zoomWaveformViewport(magnification: 2))
        #expect(f.model.waveformStartSeconds == 0 && f.model.waveformDurationSeconds == 4)
        #expect(f.model.waveformPlayheadSeconds == 2)
        try #require(f.model.zoomWaveformViewport(magnification: 0.5))
        #expect(f.model.waveformStartSeconds == -2 && f.model.waveformDurationSeconds == 8)
        #expect(f.model.waveformPlayheadSeconds == 2)
        #expect(f.document.store.model == original)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test(arguments: [1.0, 2.0])
    func renderedCoarseEnvelopeIsFilledAndRetainsQuietAndRelativeAmplitude(scale: Double) throws {
        let epoch = RecordingEpochID()
        let strokes = [(0.0...1, Float(0.8)), (1.0...2, Float(0.2)),
                       (2.0...3, Float(0)), (4.0...5, Float(0.5))].map { span, amplitude in
            AlignmentWaveformStroke(
                sourceSeconds: span.lowerBound + 0.5, groupSeconds: span.lowerBound + 0.5,
                displaySeconds: span.lowerBound + 0.5, low: -amplitude, high: amplitude,
                mapped: true, epoch: epoch, displayRange: span, groupRange: span)
        }
        let renderer = ImageRenderer(content: AudioTimelineWaveformDrawing(
            snapshot: UUID(), index: AlignmentWaveformStrokeIndex(strokes: strokes),
            size: CGSize(width: 500, height: 100),
            start: 0, duration: 5, color: .white, lineWidth: 1, gain: 1, displayScale: scale)
            .background(.black))
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func bright(_ x: Int, _ y: Int) throws -> Bool {
            let color = try #require(bitmap.colorAt(x: Int(Double(x) * scale), y: Int(Double(y) * scale))?
                .usingColorSpace(.deviceRGB))
            return color.redComponent > 0.3
        }
        var filled = 0
        for x in 1..<99 {
            if try bright(x, 25) { filled += 1 }
        }
        #expect(filled >= 97, "A coarse measured bin must render a silhouette, not isolated sticks")
        #expect(try bright(150, 45), "Lower-amplitude speech is still visible near the center")
        #expect(try !bright(150, 25), "Relative amplitudes must not be flattened")
        #expect(try !bright(250, 25), "Measured pauses remain quiet")
        #expect(try !bright(350, 45), "No filling across an uncovered interval")
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                          named: "Measured waveform silhouette \(Int(scale))x.png")
    }

    @Test(arguments: [false, true])
    func adaptiveMarkersDoNotMoveTheWaveformDuringResize(includeMarkers: Bool) async throws {
        let epoch = RecordingEpochID()
        let span = 0.0...60
        let index = AlignmentWaveformStrokeIndex(strokes: [
            AlignmentWaveformStroke(sourceSeconds: 30, groupSeconds: 30, displaySeconds: 30,
                low: -0.5, high: 0.5, mapped: true, epoch: epoch, displayRange: span, groupRange: span)
        ])
        let segments = (0..<20).map { offset in
            SourceTimingSegment(sourceStart: Double(offset) * 3, sourceEnd: Double(offset + 1) * 3,
                alignedStart: Double(offset) * 3, rateRatio: 1, kind: .estimated)
        }
        func content(duration: Double) -> some View {
            GeometryReader { geometry in
                ZStack {
                    AudioTimelineWaveformDrawing(snapshot: index.id, index: index, size: geometry.size,
                        start: 0, duration: duration, color: .white, lineWidth: 1, gain: 1, displayScale: 1)
                        .equatable()
                    if includeMarkers {
                        AcceptedAdaptiveTimingMarkers(segments: segments, start: 0, duration: duration,
                            size: geometry.size)
                            .equatable()
                    }
                }
            }
            .clipped()
            .background(.black)
            .environment(\.colorScheme, .light)
        }
        let host = HostedTimelineWindow(width: 600, height: 100, content: content(duration: 60))
        defer { host.close() }
        for (width, height, duration) in [
            (600.0, 100.0, 60.0), (900.0, 160.0, 54.0), (420.0, 64.0, 48.0),
            (1500.0, 220.0, 54.0),
            (800.0, 100.0, 8.345), (600.0, 100.0, 60.0),
        ] {
            host.window.setContentSize(CGSize(width: width, height: height))
            host.view.rootView = content(duration: duration)
            try await host.settle()
            #expect(abs(host.view.bounds.width - width) < 1 && abs(host.view.bounds.height - height) < 1)
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                named: "Waveform resize markers \(includeMarkers) width \(Int(width)) height \(Int(height)) duration \(duration).png")
            let scale = Double(bitmap.pixelsHigh) / height
            let x = min(bitmap.pixelsWide - 1, Int(Double(bitmap.pixelsWide) * 0.525))
            let brightRows = try (0..<bitmap.pixelsHigh).filter { y in
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.6
            }
            let top = Double(try #require(brightRows.first, "The waveform must remain visible after resizing")) / scale
            let bottom = Double(try #require(brightRows.last)) / scale
            #expect(abs((top + bottom) / 2 - height / 2) <= 1.5,
                "Timing markers must not displace the waveform center: \(top)...\(bottom), height \(height)")
            #expect(abs(top - height * 0.275) <= 1.5 && abs(bottom - height * 0.725) <= 1.5,
                "Resizing must preserve the symmetric measured amplitude, not pin or clip it to a lane edge.")
            if includeMarkers {
                let visible = segments.filter { $0.alignedStart > 0 && $0.alignedStart < duration }
                for segment in [try #require(visible.first), try #require(visible.last)] {
                    let centerX = Int(segment.alignedStart / duration * Double(bitmap.pixelsWide))
                    var rows: [Int] = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in max(0, centerX - Int(12 * scale))..<min(bitmap.pixelsWide, centerX + Int(12 * scale)) {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.redComponent > 0.25, color.blueComponent > 0.3,
                               color.redComponent > color.greenComponent * 1.3,
                               color.blueComponent > color.greenComponent * 1.3 {
                                rows.append(y)
                                break
                            }
                        }
                    }
                    let first = Double(try #require(rows.first, "Every visible timing marker must remain in the lane")) / scale
                    let last = Double(try #require(rows.last)) / scale
                    #expect(abs((first + last) / 2 - 12) <= 2,
                        "Timing icons share a horizontal row rather than stacking vertically: \(first)...\(last)")
                }
            }
        }
    }

    @Test func markerEditsAdoptTheirOwnIdentityWithoutSeekingOrChangingViewport() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let prepared = try await f.runtime.prepareCleanup(model: f.document.store.model, episode: f.model.episodeID)
        let lane = try #require(prepared.plan.lanes.first)
        let identity = try #require(prepared.identities[lane.primary.sourceID])
        let revision = try #require(prepared.plan.alignmentRevision)
        let words = try [2.0, 20.0].map { start in
            let frames = try #require(lane.sourceRange(start: start, end: start + 0.2))
            return TranscriptWord(text: "Um,", sourceStartFrame: frames.lowerBound,
                sourceEndFrame: frames.upperBound, alignedStart: start, alignedEnd: start + 0.2)
        }
        let transcript = SpeakerTranscript(
            speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
            sourceIdentity: identity, alignmentRevision: revision, model: "Synthetic marker navigation",
            workingRange: nil, words: words)
        try #require(f.document.store.apply("Seed synthetic marker navigation") { document throws(DomainError) in
            try document.settingCleanup(EpisodeCleanup(transcripts: [transcript]).proposingFillers(),
                                        in: f.model.episodeID)
        })
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try await wait { f.document.verifiedModel == f.document.store.model }
        f.model.waveformStartSeconds = 18
        f.model.waveformDurationSeconds = 5
        try #require(f.model.previewWaveformPlayhead(to: 19))
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let previous = try #require(cleanup.fillerReviews.first { $0.word?.id == words[0].id })
        let edited = try #require(cleanup.fillerReviews.first { $0.word?.id == words[1].id })
        cleanup.selectFiller(previous.id, reveal: false)
        #expect(f.model.waveformStartSeconds == 18 && f.model.waveformDurationSeconds == 5)
        #expect(f.model.waveformPlayheadSeconds == 2, "Non-revealing selection seeks without panning")
        try #require(f.model.previewWaveformPlayhead(to: 19))
        cleanup.playhead = 19
        let raw = cleanup.episode?.cleanup?.transcripts
        let alignment = cleanup.episode?.alignment
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        let undo = try #require(f.document.undoManager)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        cleanup.setFillerBounds(edited.id, start: 20.01, end: 20.2)
        undo.endUndoGrouping()
        #expect(cleanup.selectedFillerID == edited.id && cleanup.selectedWord?.id == words[1].id)
        #expect(cleanup.fillerStartText == "20.010000")
        #expect(f.model.listening.selection == 20.01...20.2)
        #expect(f.model.waveformStartSeconds == 18 && f.model.waveformDurationSeconds == 5)
        #expect(f.model.waveformPlayheadSeconds == 19)
        undo.undo()
        cleanup.modelDidChange()
        #expect(cleanup.selectedFiller?.bounds == edited.bounds && cleanup.selectedFillerID == edited.id)
        #expect(f.model.waveformStartSeconds == 18 && f.model.waveformDurationSeconds == 5)
        undo.redo()
        cleanup.modelDidChange()
        #expect(cleanup.selectedFiller?.bounds.alignedStart == 20.01)
        #expect(f.model.waveformStartSeconds == 18 && f.model.waveformDurationSeconds == 5)
        #expect(cleanup.episode?.cleanup?.transcripts == raw && cleanup.episode?.alignment == alignment)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
        cleanup.selectFiller(previous.id)
        #expect(f.model.waveformStartSeconds == 2 && f.model.waveformDurationSeconds == 5,
                "Explicit reveal pans only far enough to include the chosen marker, without changing zoom")
        cleanup.selectFiller(edited.id, reveal: false, movePlayhead: false)
        let beforeZoom = f.document.store.model
        let playhead = f.model.waveformPlayheadSeconds
        let bounds = try #require(cleanup.selectedFiller?.bounds)
        cleanup.zoomToFiller(edited.id)
        #expect(abs(f.model.waveformStartSeconds + f.model.waveformDurationSeconds / 2
                    - (bounds.alignedStart + bounds.alignedEnd) / 2) < 0.000_001)
        #expect(f.model.waveformStartSeconds <= bounds.alignedStart)
        #expect(f.model.waveformStartSeconds + f.model.waveformDurationSeconds >= bounds.alignedEnd)
        #expect(f.model.waveformDurationSeconds == 0.5)
        #expect(f.model.waveformPlayheadSeconds == playhead)
        #expect(f.document.store.model == beforeZoom && cleanup.selectedFillerID == edited.id)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
