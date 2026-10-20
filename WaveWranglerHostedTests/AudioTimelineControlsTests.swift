import AppKit
import SwiftUI
import Testing
import WWCore

@testable import WaveWrangler

@MainActor
@Suite("Shared timeline control layout and owned-window interaction", .serialized)
struct AudioTimelineControlsTests {
    @Test func nativeSliderPreservesRoleValueAndEditingCallbacks() async throws {
        var value = 0.25
        var editing: [Bool] = []
        let host = HostedTimelineWindow(width: 220, height: 30,
            content: NativeTimelineSlider(title: "Synthetic zoom", identifier: "test.timeline.zoom",
                value: Binding(get: { value }, set: { value = $0 }),
                bounds: 0...1, editingChanged: { editing.append($0) }))
        defer { host.close() }
        try await host.settle()
        let slider = try #require(host.descendants.compactMap { $0 as? NSSlider }.first)
        #expect(slider.accessibilityRole() == .slider)
        #expect(slider.accessibilityLabel() == "Synthetic zoom")
        #expect(slider.accessibilityIdentifier() == "test.timeline.zoom")
        #expect(slider.minValue == 0 && slider.maxValue == 1)
        #expect(slider.accessibilityValue() as? Double == 0.25)
        #expect(slider.accessibilityMinValue() as? Double == 0)
        #expect(slider.accessibilityMaxValue() as? Double == 1)
        #expect(slider.accessibilityChildren()?.isEmpty == true)
        slider.doubleValue = 0.75
        #expect(slider.sendAction(slider.action, to: slider.target))
        #expect(value == 0.75 && editing == [true, false])
        #expect(slider.accessibilityPerformDecrement())
        #expect(value < 0.75 && editing == [true, false, true, false])
        slider.setAccessibilityValue(NSNumber(value: 0.9))
        #expect(value == 0.9 && editing == [true, false, true, false, true, false])
    }

    @Test(arguments: [320.0, 420.0, 720.0])
    func navigationFitsTheAvailableColumn(_ width: Double) throws {
        let renderer = ImageRenderer(
            content: AudioTimelineNavigation(
                prefix: "test.timeline", maximumDuration: 40, duration: .constant(10),
                laneHeight: .constant(96), showsLaneHeight: true,
                isLoading: false, canNavigate: true, zoomEditing: { _ in }, fit: {}, refresh: {}))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        #expect(
            Double(image.width) <= width + 1,
            "Navigation must wrap rather than overflow a narrow editor")
        #expect(image.height <= 100)
    }

    @Test(arguments: [320.0, 420.0, 720.0])
    func transportFitsTheAvailableColumn(_ width: Double) throws {
        let renderer = ImageRenderer(
            content: AudioTimelineTransport(
                prefix: "test.timeline", isPlaying: true, isPreparing: false,
                canPlay: true, canNavigate: true, playhead: 12,
                status: "Playing 4 aligned Primary tracks.",
                back: {}, playPause: {}, stop: {}, forward: {}, seek: { _ in }))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        #expect(Double(image.width) <= width + 1)
        #expect(image.height <= 80)
    }

    @Test(arguments: [320.0, 420.0, 720.0])
    func fillerReviewSummaryFitsTheAvailableColumn(_ width: Double) throws {
        let episode = Episode(title: "Synthetic")
        let store = ShowDocumentStore(model: .init(show: Show(title: "Synthetic"), episodes: [episode]))
        let model = EpisodeCleanupModel(state: ShowWindowState(store: store), episodeID: episode.id)
        defer { model.cancel() }
        let renderer = ImageRenderer(content: FillerTimingReviewSummary(model: model))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        #expect(Double(image.width) <= width + 1, "Review controls must wrap in a narrow editor")
        #expect(image.height <= 180)
    }

    @Test func transportButtonsReceiveMouseInputWithoutActivatingTheDesktop() async throws {
        var calls = [0, 0, 0, 0]
        var sought: Double?
        let host = HostedTimelineWindow(
            width: 700, height: 84,
            content: AudioTimelineTransport(
                prefix: "test.timeline", isPlaying: false, isPreparing: false,
                canPlay: true, canNavigate: true, playhead: 12, status: "Stopped",
                back: { calls[0] += 1 }, playPause: { calls[1] += 1 },
                stop: { calls[2] += 1 }, forward: { calls[3] += 1 }, seek: { sought = $0 }))
        defer { host.close() }
        try await host.settle()
        let buttons = host.controlFrames.filter { $0.midX < 250 }.sorted { $0.minX < $1.minX }
        try #require(
            buttons.count == 4, "Unexpected transport control frames: \(host.controlFrames)")
        for (index, frame) in buttons.enumerated() {
            try await host.click(CGPoint(x: frame.midX, y: frame.midY))
            #expect(calls[index] == 1)
        }
        #expect(calls == [1, 1, 1, 1])
        let field = try #require(
            host.descendants.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.selectText(nil)
        try await host.settle()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("12.500", replacementRange: editor.selectedRange())
        try await host.settle()
        try await host.returnKey()
        #expect(sought == 12.5, "Native text entry and Return commit the shared time control")
        try host.capture("Shared transport with real native controls")
    }

    @Test func cleanupWorkspaceReceivesGraphicalMarkerZoomMuteAndPlaybackInput() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let snapshot = f.document.store.model
        let prepared = try await f.runtime.prepareCleanup(
            model: snapshot, episode: f.model.episodeID)
        let revision = try #require(prepared.plan.alignmentRevision)
        let transcripts = try prepared.plan.lanes.map { lane in
            SpeakerTranscript(
                speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
                sourceIdentity: try #require(prepared.identities[lane.primary.sourceID]),
                alignmentRevision: revision, model: "Synthetic hosted timeline fixture",
                workingRange: nil,
                words: [
                    TranscriptWord(
                        text: "hello", sourceStartFrame: Int64(lane.sourceRate * 2),
                        sourceEndFrame: Int64(lane.sourceRate * 5 / 2), alignedStart: 2,
                        alignedEnd: 2.5)
                ])
        }
        try #require(
            f.document.store.apply(
                "Seed synthetic timeline text",
                { model throws(DomainError) in
                    try model.settingCleanup(
                        EpisodeCleanup(transcripts: transcripts), in: f.model.episodeID)
                }))
        let state = ShowWindowState(store: f.document.store)
        let host = HostedTimelineWindow(
            width: 1_000, height: 900,
            content:
                EpisodeCleanupContent(
                    state: state, episodeID: f.model.episodeID, runtime: f.runtime))
        state.window = host.window
        defer {
            state.cleanupModel?.cancel()
            state.cleanupModel = nil
            host.close()
        }
        try await host.settle()
        try await wait { state.cleanupModel?.canNavigate == true }
        let model = try #require(state.cleanupModel)
        try await wait { !model.isLoadingWaveforms && !model.isLoadingOverview }
        try await host.settle()
        try host.capture("Two synthetic Primaries with time-aligned words")

        let approximateWidth = (host.view.bounds.width - 222) * 0.5 / model.windowDuration
        let approximateX = 210 + (host.view.bounds.width - 222) * 2 / model.windowDuration
        let wordFrames = host.controlFrames.filter {
            abs($0.height - 21) < 0.75 && abs($0.width - approximateWidth) < 3
                && abs($0.minX - approximateX) < 6
        }.sorted { $0.minY < $1.minY }
        try #require(wordFrames.count == 2, "Actual word controls: \(host.controlFrames)")
        let firstWord = wordFrames[0]
        let waveWidth = firstWord.width / 0.5 * model.windowDuration
        let waveX = firstWord.minX - 2 / model.windowDuration * waveWidth
        let waveTop = firstWord.minY - model.laneHeight - 2
        #expect(abs(waveX - 210) <= 2, "Native focus frames may extend two points beyond the shared timeline origin")
        #expect(
            wordFrames[1].minY - firstWord.minY - model.laneHeight < 72,
            "The inter-track space contains words, not empty card padding")
        try await host.click(CGPoint(x: firstWord.midX, y: firstWord.midY))
        #expect(model.selectedWord?.id == transcripts[0].words[0].id)
        #expect(model.selectedSpeaker == transcripts[0].speaker && model.playhead == 2)

        var tools = try iconRow(in: host, count: 3)
        try await host.click(CGPoint(x: tools[1].midX, y: tools[1].midY))
        #expect(model.timelineTool == .markIn)
        let marks = host.controlFrames.filter {
            abs($0.midY - tools[0].midY) < 3 && $0.width > 60 && $0.minX > tools[2].maxX
        }.sorted { $0.minX < $1.minX }
        try #require(marks.count == 2, "Graphical In/Out at Playhead controls")
        try await host.click(CGPoint(x: marks[0].midX, y: marks[0].midY))
        try await wait("Tracks In; playhead=\(model.playhead), error=\(model.error ?? "none")") {
            model.canNavigate && model.episode?.cleanup?.workingRange?.tracksIn != nil
        }
        #expect(model.episode?.cleanup?.workingRange?.tracksIn == 2)
        // Desktop-activated waveform/ruler gestures remain in TranscriptReviewUITests.
        let transport = try iconRow(in: host, count: 4)
        try await host.click(CGPoint(x: transport[3].midX, y: transport[3].midY))
        #expect(model.playhead == 7)
        tools = try iconRow(in: host, count: 3)
        try await host.click(CGPoint(x: tools[2].midX, y: tools[2].midY))
        #expect(model.timelineTool == .markOut)
        try await host.click(CGPoint(x: marks[1].midX, y: marks[1].midY))
        try await wait("Tracks Out; playhead=\(model.playhead), error=\(model.error ?? "none")") {
            model.canNavigate && model.episode?.cleanup?.workingRange?.tracksOut != nil
        }
        #expect(model.episode?.cleanup?.workingRange?.tracksOut == 7)

        let sliderCandidates = host.controlFrames.filter {
            $0.width >= 40 && $0.height <= 15 && $0.maxY < tools[0].minY
        }
        let sliderRow = try #require(sliderCandidates.map(\.midY).max())
        let sliders = sliderCandidates.filter { abs($0.midY - sliderRow) < 1 }.sorted {
            $0.minX < $1.minX
        }
        try #require(sliders.count == 2, "Zoom and track-height sliders: \(host.controlFrames)")
        let playhead = model.playhead
        try await host.click(
            CGPoint(x: sliders[0].minX + sliders[0].width * 0.65, y: sliders[0].midY))
        #expect(model.windowDuration < 10 && model.windowDuration >= 0.5)
        #expect(model.playhead == playhead)
        #expect(abs(model.windowStart + model.windowDuration / 2 - playhead) < 0.000_001)
        let zoomedDuration = model.windowDuration
        try await host.click(
            CGPoint(x: sliders[0].minX + sliders[0].width * 0.25, y: sliders[0].midY))
        #expect(model.windowDuration > zoomedDuration && model.playhead == playhead)
        #expect(abs(model.windowStart - max(0, playhead - model.windowDuration / 2)) < 0.000_001)
        model.setWindow(start: 25, duration: 5)
        try await host.settle()
        try await host.click(
            CGPoint(x: sliders[0].minX + sliders[0].width * 0.8, y: sliders[0].midY))
        #expect(model.playhead == playhead)
        #expect(abs(model.windowStart + model.windowDuration / 2 - playhead) < 0.000_001)
        try await host.click(
            CGPoint(x: sliders[1].minX + sliders[1].width * 0.8, y: sliders[1].midY))
        #expect(model.laneHeight > 130)
        // Leave room for both speaker controls below the new filler-review panel.
        try await host.click(
            CGPoint(x: sliders[1].minX + sliders[1].width * 0.2, y: sliders[1].midY))
        let fit = try #require(
            host.controlFrames.first {
                $0.width < 60 && abs($0.midY - sliderRow) < 3
                    && $0.minX > sliders[0].maxX && $0.maxX < sliders[1].minX
            })
        try await host.click(CGPoint(x: fit.midX, y: fit.midY))
        #expect(model.windowStart == 0 && model.windowDuration == 40)
        try await host.settle()

        let fittedWordWidth = waveWidth * 0.5 / model.windowDuration
        let fittedWords = host.controlFrames.filter {
            abs($0.height - 21) < 0.75 && abs($0.width - fittedWordWidth) < 3 && $0.minY > waveTop
        }.sorted { $0.minY < $1.minY }
        try #require(fittedWords.count == 2, "Words remain time-positioned after zoom and Fit")
        let fittedWaveTop = try #require(fittedWords.first).minY - model.laneHeight - 2
        let listeningFrames = host.controlFrames.filter {
            $0.maxX < 90 && (18...30).contains($0.width) && $0.height <= 20
                && $0.minY > fittedWaveTop
        }.sorted { $0.midY < $1.midY }
        var listeningRows: [[CGRect]] = []
        for frame in listeningFrames {
            if let index = listeningRows.firstIndex(where: { abs($0[0].midY - frame.midY) < 2 }) {
                listeningRows[index].append(frame)
            } else { listeningRows.append([frame]) }
        }
        for (index, wordFrame) in fittedWords.enumerated() {
            let laneTop = wordFrame.minY - model.laneHeight - 2
            let row = try #require(listeningRows.first {
                $0.count == 2 && $0[0].midY > laneTop && $0[0].midY < wordFrame.minY
            }, "Native Solo/Mute row in speaker lane \(index): \(listeningRows)")
            let mute = try #require(row.max(by: { $0.maxX < $1.maxX }), "Mute follows Solo in each speaker header.")
            try await host.click(CGPoint(x: mute.midX, y: mute.midY))
            #expect(model.mutedSpeakers.count == index + 1)
        }
        #expect(model.mutedSpeakers == Set(transcripts.map(\.speaker)))
        #expect(
            model.plan?.isReady == true, "Mute never exempts a Primary from alignment readiness")
        tools = try iconRow(in: host, count: 3)
        try await host.click(CGPoint(x: tools[0].midX, y: tools[0].midY))
        let beforeNavigation = model.playhead
        for _ in 0..<6 {
            try await host.click(CGPoint(x: transport[3].midX, y: transport[3].midY))
        }
        #expect(
            abs(model.playhead - beforeNavigation - 30) < 0.001,
            "Banter outside Tracks Out is still reachable")
        let beforePlayback = model.playhead
        try await host.click(CGPoint(x: transport[1].midX, y: transport[1].midY))
        try await wait {
            model.isPlaying && model.playhead > beforePlayback + 0.1 || model.error != nil
        }
        try #require(
            model.error == nil && model.isPlaying, "\(model.error ?? model.transportMessage)")
        try await host.click(
            CGPoint(x: sliders[0].minX + sliders[0].width * 0.8, y: sliders[0].midY))
        #expect(model.isPlaying && model.playhead >= beforePlayback)
        #expect(abs(model.windowStart + model.windowDuration / 2 - model.playhead) < 0.5)
        #expect(model.windowStart <= model.playhead && model.playhead <= model.windowStart + model.windowDuration)
        try await host.click(CGPoint(x: transport[1].midX, y: transport[1].midY))
        #expect(!model.isPlaying && !model.isPreparingPlayback)
        let paused = model.playhead
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(model.playhead - paused) < 1 / 48_000)
        try await host.click(CGPoint(x: transport[2].midX, y: transport[2].midY))
        #expect(model.playhead == model.windowStart)
        #expect(model.episode?.alignment == snapshot.episodes[0].alignment)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
        try host.capture("Graphical marks and scaled compact Primary lanes")
    }
    private func wait(
        _ context: @autoclosure () -> String = "synthetic hosted workspace",
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Timed out waiting for \(context())")
    }

    private func iconRow<Content: View>(in host: HostedTimelineWindow<Content>, count: Int) throws
        -> [CGRect]
    {
        let small = host.controlFrames.filter { $0.width <= 44 && $0.maxX < 200 }.sorted {
            $0.midY < $1.midY
        }
        var rows: [[CGRect]] = []
        for frame in small {
            if let index = rows.firstIndex(where: { abs($0[0].midY - frame.midY) < 2 }) {
                rows[index].append(frame)
            } else {
                rows.append([frame])
            }
        }
        let row = try #require(rows.first { $0.count == count }, "Actual icon rows: \(rows)")
        return row.sorted { $0.minX < $1.minX }
    }
}

@MainActor
final class HostedTimelineWindow<Content: View> {
    let window: NSWindow
    let view: NSHostingView<Content>

    init(width: CGFloat, height: CGFloat, content: Content) {
        window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic hosted timeline validation"
        view = NSHostingView(rootView: content)
        window.contentView = view
        window.orderFront(nil)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    func settle() async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
    }

    var controlFrames: [CGRect] {
        var frames: [CGRect] = []
        func collect(_ node: NSView) {
            guard !node.isHiddenOrHasHiddenAncestor else { return }
            if node !== view, node.subviews.isEmpty {
                let frame = view.convert(node.bounds, from: node)
                if (10...50).contains(frame.height), (0.5...300).contains(frame.width),
                    view.bounds.contains(frame), !frames.contains(frame)
                {
                    frames.append(frame)
                }

            }
            for child in node.subviews { collect(child) }
        }
        // SwiftUI's keyboard proxies and focus rings share bounds; avoid private class-name checks.
        collect(view)
        return frames
    }

    var descendants: [NSView] {
        func collect(_ node: NSView) -> [NSView] {
            [node] + node.subviews.flatMap { collect($0) }
        }
        return collect(view)
    }

    func click(_ point: CGPoint) async throws {
        try await mouse([(.leftMouseDown, point), (.leftMouseUp, point)])
    }

    func returnKey() async throws {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: kind, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
            NSApp.sendEvent(event)
        }
        try await settle()
    }

    func mouse(_ path: [(NSEvent.EventType, CGPoint)]) async throws {
        for (index, step) in path.enumerated() {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: step.0, location: view.convert(step.1, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index + 1,
                    clickCount: 1, pressure: step.0 == .leftMouseUp ? 0 : 1))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.1)
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
            until: deadline, inMode: .default, dequeue: true)
        {
            try #require(
                event.windowNumber == window.windowNumber, "Refusing input for another window")
            NSApp.sendEvent(event)
        }
        try await settle()
    }

    func capture(_ name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        Attachment.record(
            try #require(bitmap.representation(using: .png, properties: [:])),
            named: "\(name).png")
    }
}
