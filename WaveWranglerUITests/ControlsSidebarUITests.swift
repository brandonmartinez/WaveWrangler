import XCTest

@MainActor
final class ControlsSidebarUITests: XCTestCase {
    func testDefaultWorkspaceActivityTogglesKeepDetailedAlignmentOffTheCanvas() {
        exerciseSidebars(minimumSize: false)
    }

    func testMinimumWorkspaceKeepsActivityTogglesToolsAndListeningPresetsReachable() {
        exerciseSidebars(minimumSize: true)
    }

    func testDetachedReviewSharesFiltersCutUndoAndReattachesWithoutAnotherEpisode() {
        let app = launch()
        defer { app.terminate() }
        let main = app.windows["ww.show.window"]
        XCTAssertTrue(main.waitForExistence(timeout: 20))
        let review = app.buttons["ww.review.toggle"]
        if review.value as? String != "Shown" { review.click() }
        let detach = app.buttons["ww.review.detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 10))
        detach.click()
        let window = app.windows["ww.review.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "ww.show.window").count, 1)
        let search = window.textFields["ww.review.search"]
        search.click()
        search.typeText("Um")
        let row = window.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.review.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let cut = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.review.cut.'")).firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 5))
        XCTAssertTrue(cut.isEnabled)
        cut.click()
        let restore = window.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.review.restore.'")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        window.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(cut.waitForExistence(timeout: 10), app.debugDescription)
        window.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        window.buttons["ww.review.reattach"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertTrue(main.textFields["ww.review.search"].waitForExistence(timeout: 5))
        XCTAssertEqual(main.textFields["ww.review.search"].value as? String, "Um")
        main.buttons["ww.review.detach"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertTrue(main.exists, "Closing auxiliary review must not close the originating episode.")
    }

    func testCommandReviewToolIsTemporaryAndMarkerUsesOneCenteredToolbar() throws {
        let app = launch()
        defer { app.terminate() }
        let candidate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.' AND label CONTAINS 'Um,'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 20), app.debugDescription)
        let rulerSurface = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        rulerSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).click()
        app.typeKey(.space, modifierFlags: [])
        let play = app.buttons["alignment.waveforms.transport.play"]
        XCTAssertTrue(wait { play.label == "Pause" }, "Space starts transport after clicking the timeline. \(app.debugDescription)")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(wait { play.label == "Play" }, "Space pauses transport without a focused control.")
        let timelinePlayhead = app.textFields["alignment.waveforms.playhead"]
        let beforeJump = try XCTUnwrap(Double(timelinePlayhead.value as? String ?? ""))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait { (Double(timelinePlayhead.value as? String ?? "") ?? beforeJump) > beforeJump })
        let afterJump = try XCTUnwrap(Double(timelinePlayhead.value as? String ?? ""))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(wait { (Double(timelinePlayhead.value as? String ?? "") ?? afterJump) < afterJump })
        let region = app.buttons[candidate.identifier]
        app.menuButtons["alignment.waveforms.commandTool"].click()
        app.menuItems["Reject"].click()
        let primary = app.menuButtons["alignment.waveforms.tool"]
        XCTAssertEqual(primary.value as? String, "Pointer")
        reveal(region, in: app)
        let tracks = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        let trackFrames = Dictionary(uniqueKeysWithValues:
            tracks.allElementsBoundByIndex.map { ($0.identifier, $0.frame) })
        XCUIElement.perform(withKeyModifiers: .command) { region.click() }
        XCTAssertTrue(wait { region.label.contains("Not a filler") }, app.debugDescription)
        XCTAssertEqual(primary.value as? String, "Pointer", "Command-click must not reassign the primary tool.")
        let actions = app.descendants(matching: .any).matching(identifier: "ww.timeline.selection.actions")
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.count, 1, "Only the selected region owns the compact toolbar.")
        for (identifier, frame) in trackFrames {
            XCTAssertEqual(tracks.matching(identifier: identifier).firstMatch.frame, frame,
                           "Floating marker controls must not resize or move tracks or their headers.")
        }
        XCTAssertEqual(app.popovers.count, 0, "Marker review no longer opens a second detailed popup.")
        XCTAssertFalse(app.textFields["ww.cleanup.filler.start.seconds"].exists)
        XCTAssertFalse(app.textFields["ww.cleanup.filler.end.seconds"].exists)
        let rails = app.descendants(matching: .any).matching(identifier: "ww.cleanup.fillers.rails").firstMatch
        let toolbar = actions.firstMatch
        XCTAssertGreaterThanOrEqual(toolbar.frame.minX, rails.frame.minX - 1)
        XCTAssertLessThanOrEqual(toolbar.frame.maxX, rails.frame.maxX + 1)
        let interval = (region.value as? String ?? "").split(separator: " ").compactMap { Double($0) }
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let visible = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(interval.count, 2)
        XCTAssertEqual(visible.count, 2)
        let midpoint = (try XCTUnwrap(interval.first) + XCTUnwrap(interval.last)) / 2
        XCTAssertLessThan(toolbar.frame.height, 40, "The selection toolbar is one compact row, not a word/status heading over buttons")
        XCTAssertEqual(toolbar.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Um,", "Um,")).count, 0,
            "The selected word stays in the transcript, not duplicated in the floating controls")
        let visibleStart = try XCTUnwrap(visible.first)
        let duration = try XCTUnwrap(visible.last) - visibleStart
        let intervalCenter = rails.frame.minX + (midpoint - visibleStart) / duration * rails.frame.width
        let center = min(max(rails.frame.minX + toolbar.frame.width / 2, intervalCenter),
                         rails.frame.maxX - toolbar.frame.width / 2)
        XCTAssertEqual(toolbar.frame.midX, center, accuracy: 2)
        XCTAssertLessThanOrEqual(toolbar.frame.maxY, rails.frame.minY - 2,
                                 "Selection controls float above the active waveform, not over its audio")
        let selection = region.value as? String
        let viewport = ruler.value as? String
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        XCTAssertTrue(wait { !actions.firstMatch.exists }, "Clicking elsewhere dismisses marker tools.")
        XCTAssertEqual(region.value as? String, selection)
        XCTAssertEqual(ruler.value as? String, viewport)
        region.click()
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5),
                      "Selecting the same marker reopens its tools.")
        let playhead = app.textFields["alignment.waveforms.playhead"].value as? String
        let zoom = app.buttons["ww.cleanup.filler.zoom"]
        XCTAssertTrue(zoom.isHittable)
        zoom.click()
        XCTAssertTrue(wait {
            let times = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
            return times.count == 2 && abs((times[0] + times[1]) / 2 - midpoint) < 0.002
        }, "Zoom to word centers its complete interval")
        let focused = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(focused.count, 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(focused.first), try XCTUnwrap(interval.first))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(focused.last), try XCTUnwrap(interval.last))
        XCTAssertLessThan(try XCTUnwrap(focused.last) - XCTUnwrap(focused.first), duration)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playhead,
                       "Zoom to word changes the viewport, not playback time")
        app.buttons["ww.cleanup.filler.clearReview"].click()
        XCTAssertTrue(wait { region.label.contains("Pending") })
        region.click()
        XCTAssertTrue(region.label.contains("Pending"), "Releasing Command restores Pointer, not another review action.")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { region.label.contains("Not a filler") }, "Clear review is an undoable decision, not deletion.")
        app.buttons["ww.cleanup.filler.reviewed"].click()
        XCTAssertTrue(wait { region.label.contains("Reviewed unchanged") })
        XCTAssertTrue(app.buttons["ww.cleanup.filler.revert"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Single centered marker toolbar with temporary Command tool"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testManualCrossTrackCutSpeakerViewZoomUndoAndRestore() throws {
        let app = launch(singlePrimary: true)
        defer { app.terminate() }
        let candidate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.' AND label CONTAINS 'Um,'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 20), app.debugDescription)
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        app.sliders["alignment.waveforms.laneHeight"].adjust(toNormalizedSliderPosition: 0)
        let markerID = candidate.identifier
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let originalViewport = ruler.value as? String
        let zoomIn = app.buttons["alignment.waveforms.zoomIn"]
        reveal(zoomIn, in: app)
        zoomIn.click()
        XCTAssertTrue(wait { ruler.value as? String != originalViewport })
        app.buttons["alignment.waveforms.zoomOut"].click()
        let layout = app.descendants(matching: .any)["alignment.waveforms.layout"]
        let allTracks = 2
        reveal(layout, in: app)
        selectTimelineLayout("Speakers only", in: app)
        reveal(candidate, in: app)
        candidate.click()
        let cutAction = app.buttons["ww.timeline.selection.cut"]
        XCTAssertTrue(cutAction.waitForExistence(timeout: 5) && cutAction.isHittable)
        cutAction.click()
        let cut = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.timeline.cut.' AND label == 'Cross-track cut'")).firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons[markerID].exists)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons[markerID].waitForExistence(timeout: 5))
        XCTAssertFalse(cut.exists)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(cut.waitForExistence(timeout: 5))
        let cutIdentifier = cut.identifier
        let previousCutValue = cut.value as? String
        reveal(layout, in: app)
        selectTimelineLayout("By speaker", in: app)
        let tracks = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        XCTAssertTrue(wait { tracks.count == allTracks && tracks.count > 1 }, app.debugDescription)
        let firstTrack = tracks.matching(identifier: tracks.element(boundBy: 0).identifier).firstMatch
        let clickedTrack = tracks.matching(identifier: tracks.element(boundBy: 1).identifier).firstMatch
        let clickedCut = clickedTrack.buttons[cutIdentifier]
        reveal(clickedCut, in: app)
        let firstFrame = firstTrack.frame
        let clickedFrame = clickedTrack.frame
        clickedCut.click()
        let show = app.buttons["ww.timeline.cut.show"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertEqual(app.popovers.count, 0, "Cut tools use the same inline toolbar as other markers.")
        let actions = app.descendants(matching: .any).matching(identifier: "ww.timeline.selection.actions")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(firstTrack.frame, firstFrame)
        XCTAssertEqual(clickedTrack.frame, clickedFrame,
                       "Showing cut tools must not shift the waveform or change header wrapping.")
        XCTAssertLessThan(actions.firstMatch.frame.height, 40)
        XCTAssertEqual(actions.firstMatch.frame.maxY, clickedTrack.frame.minY, accuracy: 20,
                       "The cut toolbar belongs above the clicked track, not the first track.")
        XCTAssertEqual(show.label, "Show cut")
        let cutZoom = app.buttons["ww.timeline.cut.zoom"]
        let playheadBeforeZoom = app.textFields["alignment.waveforms.playhead"].value as? String
        XCTAssertTrue(cutZoom.isHittable)
        cutZoom.click()
        let collapsedWindow = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        let cutValues = (previousCutValue ?? "").split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(collapsedWindow.count, 2)
        XCTAssertEqual(cutValues.count, 2)
        XCTAssertEqual((try XCTUnwrap(collapsedWindow.first) + XCTUnwrap(collapsedWindow.last)) / 2,
                       try XCTUnwrap(cutValues.last), accuracy: 0.003)
        XCTAssertEqual(show.label, "Show cut", "Zooming a seam does not reveal removed audio.")
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playheadBeforeZoom)
        show.click()
        XCTAssertTrue(wait { show.label == "Hide cut" })
        let start = clickedTrack.buttons[cutIdentifier + ".start"]
        let end = clickedTrack.buttons[cutIdentifier + ".end"]
        XCTAssertTrue(start.waitForExistence(timeout: 5) && end.exists, app.debugDescription)
        XCTAssertFalse(cut.exists, "Expanded cuts use real waveform intervals rather than scissor seams.")
        let expandedPlayheadBeforeZoom = app.textFields["alignment.waveforms.playhead"].value as? String
        cutZoom.click()
        XCTAssertEqual(show.label, "Hide cut", "Zooming the revealed interval leaves its handles expanded.")
        let focusedWindow = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        let boundaryStart = try XCTUnwrap(Double((start.value as? String ?? "").components(separatedBy: " ").first ?? ""))
        let boundaryEnd = try XCTUnwrap(Double((end.value as? String ?? "").components(separatedBy: " ").first ?? ""))
        XCTAssertLessThanOrEqual(try XCTUnwrap(focusedWindow.first), boundaryStart)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(focusedWindow.last), boundaryEnd)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, expandedPlayheadBeforeZoom)
        let expandedViewport = ruler.value as? String
        let expandedStart = start.value as? String
        let expandedEnd = end.value as? String
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        XCTAssertTrue(wait { !actions.firstMatch.exists }, "Click-away hides the cut tools.")
        XCTAssertTrue(start.exists && end.exists, "Dismissal leaves the cut expanded for visual editing.")
        XCTAssertEqual(start.value as? String, expandedStart)
        XCTAssertEqual(end.value as? String, expandedEnd)
        XCTAssertEqual(ruler.value as? String, expandedViewport)
        start.click()
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
        let firstEnd = firstTrack.buttons[cutIdentifier + ".end"]
        reveal(firstEnd, in: app)
        firstEnd.click()
        XCTAssertEqual(actions.firstMatch.frame.maxY, firstTrack.frame.minY, accuracy: 20)
        reveal(start, in: app)
        start.click()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.firstMatch.frame.maxY, clickedTrack.frame.minY, accuracy: 20,
                       "Expanded boundary handles also update the editing context.")
        let transportStatus = app.staticTexts["alignment.waveforms.transport.status"]
        for action in ["play", "context"] {
            app.buttons["ww.timeline.cut.\(action)"].click()
            XCTAssertTrue(wait {
                app.buttons["alignment.waveforms.transport.play"].label == "Pause"
                    || (transportStatus.value as? String ?? transportStatus.label) == "Finished selection audition."
            }, "\(action): \(transportStatus.value as? String ?? transportStatus.label)")
            XCTAssertTrue(wait {
                app.buttons["alignment.waveforms.transport.play"].label == "Play"
                    && (transportStatus.value as? String ?? transportStatus.label) == "Finished selection audition."
            }, "Short cut auditions finish naturally; their transient Stop button may disappear before a click.")
        }
        let previousStart = start.value as? String
        let previousEnd = end.value as? String
        reveal(start, in: app)
        let point = start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.click(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 16, dy: 0)))
        XCTAssertTrue(wait { start.value as? String != previousStart }, app.debugDescription)
        XCTAssertEqual(end.value as? String, previousEnd, "Dragging start never moves the end handle.")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { start.value as? String == previousStart }, "One Undo reverses a completed boundary drag.")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { start.value as? String != previousStart })
        show.click()
        XCTAssertTrue(cut.waitForExistence(timeout: 5))
        XCTAssertNotEqual(cut.value as? String, previousCutValue)
        XCTAssertFalse(start.exists)
        XCTAssertEqual(show.label, "Show cut")
        XCTAssertEqual(actions.firstMatch.frame.maxY, clickedTrack.frame.minY, accuracy: 20,
                       "Hiding a cut preserves the clicked track context.")
        app.buttons["ww.timeline.cut.play"].click()
        XCTAssertTrue(wait {
            app.buttons["alignment.waveforms.transport.play"].label == "Pause"
                || (transportStatus.value as? String ?? transportStatus.label) == "Finished selection audition."
        })
        XCTAssertTrue(wait {
            app.buttons["alignment.waveforms.transport.play"].label == "Play"
                && (transportStatus.value as? String ?? transportStatus.label) == "Finished selection audition."
        })
        let restore = app.buttons["ww.timeline.cut.restore"]
        reveal(restore, in: app)
        restore.click()
        XCTAssertTrue(app.buttons[markerID].waitForExistence(timeout: 5))
        XCTAssertFalse(cut.exists)
        reveal(layout, in: app)
        selectTimelineLayout("By speaker", in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'")).count, allTracks)
        let mutedNonPrimaries = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.listening.mute.source.' AND value == 'On'"))
        XCTAssertGreaterThan(mutedNonPrimaries.count, 0, "Hidden non-primary tracks were automatically muted")
        let restoreListening = app.buttons["ww.listening.restore"]
        reveal(restoreListening, in: app)
        restoreListening.click()
        XCTAssertEqual(mutedNonPrimaries.count, 0)
    }

    func testEpisodeReopensAtItsLastLayoutZoomPositionAndTrackHeight() throws {
        let app = launch(singlePrimary: true)
        defer { app.terminate() }
        let layout = app.descendants(matching: .any)["alignment.waveforms.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 20))
        selectTimelineLayout("Speakers only", in: app)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("2.25")
        playhead.typeKey(.return, modifierFlags: [])
        let fit = app.buttons["alignment.waveforms.fitTimeline"]
        XCTAssertTrue(wait { fit.exists && fit.isEnabled })
        fit.click()
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let span = (ruler.value as? String ?? "").split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(span.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(span.last) - XCTUnwrap(span.first), 30,
                             "Cold reopening must cover a zoomed-out viewport, not only exact windows.")
        let height = app.sliders["alignment.waveforms.laneHeight"]
        height.adjust(toNormalizedSliderPosition: 0.7)
        let normalized = app.checkBoxes["Normalize view"]
        normalized.click()
        app.buttons["ww.sidebar.recording"].click()
        let viewport = app.staticTexts["alignment.waveforms.ruler"].value as? String
        let heightValue = try XCTUnwrap(height.value as? NSNumber).doubleValue
        let normalizedValue = normalized.value as? String
        let args = app.launchArguments
        let folderIndex = try XCTUnwrap(args.firstIndex(of: "-WWUITestShowFolder"))
        let file = "\(args[folderIndex + 1])/Controls Sidebar Fixture.wwshow"
        app.typeKey("s", modifierFlags: .command)
        app.terminate()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestOpenWithoutShowWindows", file,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(layout.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(layout.value as? String, "Speakers only")
        XCTAssertEqual(playhead.value as? String, "2.250")
        XCTAssertEqual(app.staticTexts["alignment.waveforms.ruler"].value as? String, viewport)
        XCTAssertEqual(try XCTUnwrap(height.value as? NSNumber).doubleValue, heightValue, accuracy: 0.01)
        XCTAssertEqual(normalized.value as? String, normalizedValue)
        XCTAssertEqual(app.buttons["ww.sidebar.recording"].value as? String, "Hidden")
        let tracks = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        XCTAssertTrue(wait { tracks.count == 1 }, "A restored wide Speakers only view must load its Primary track.")
        XCTAssertFalse(tracks.firstMatch.label.contains("waveform. 0 measured amplitude bins"))
        let play = app.buttons["alignment.waveforms.transport.play"]
        XCTAssertTrue(play.isEnabled)
        play.click()
        XCTAssertTrue(wait { play.label == "Pause" })
        app.buttons["alignment.waveforms.transport.stop"].click()
    }

    private func exerciseSidebars(minimumSize: Bool) {
        let app = launch(minimumSize: minimumSize)
        defer { app.terminate() }
        let recording = app.buttons["ww.sidebar.recording"]
        let alignment = app.buttons["ww.sidebar.alignment"]
        let transcript = app.buttons["ww.sidebar.transcript"]
        let episode = app.buttons["ww.sidebar.episode"]
        XCTAssertTrue(recording.waitForExistence(timeout: 20), app.debugDescription)
        for toggle in [recording, alignment, transcript, episode] {
            XCTAssertTrue(toggle.isHittable, toggle.debugDescription)
        }
        XCTAssertFalse(app.outlines["ww.alignment.groups"].exists, "The recording inspector is contextual, not the detailed table.")
        alignment.click()
        XCTAssertEqual(alignment.value as? String, "Shown")
        XCTAssertEqual(recording.value as? String, "Hidden")
        XCTAssertTrue(app.outlines["ww.alignment.groups"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews["ww.inspector.alignment.details"].exists)
        alignment.click()
        XCTAssertEqual(alignment.value as? String, "Hidden")
        XCTAssertTrue(wait { !app.outlines["ww.alignment.groups"].exists })
        episode.click()
        XCTAssertTrue(app.textFields["ww.inspector.episode.title"].waitForExistence(timeout: 5))
        transcript.click()
        let reading = app.descendants(matching: .any)["ww.review.transcriptReading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        reveal(reading, in: app, scrollID: "ww.inspector")
        reading.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ww.transcript.full.'")).firstMatch.waitForExistence(timeout: 5),
            app.debugDescription)
        XCTAssertEqual(episode.value as? String, "Hidden")
        let primary = app.menuButtons["alignment.waveforms.tool"]
        reveal(primary, in: app)
        XCTAssertTrue(primary.isHittable)
        XCTAssertTrue(app.menuButtons["alignment.waveforms.commandTool"].isHittable)
        let preset = app.buttons["ww.listening.preset.soloPrimaries"]
        XCTAssertTrue(preset.isHittable)
        XCTAssertTrue(app.buttons["ww.audioWorkspace.add"].isHittable)
        preset.click()
        XCTAssertEqual(preset.value as? String, "On")
        XCTAssertTrue(app.buttons["ww.listening.restore"].exists)
        app.buttons["ww.listening.restore"].click()
        XCTAssertEqual(preset.value as? String, "Off")
        XCTAssertFalse(app.buttons["ww.listening.restore"].exists)
        let window = app.windows["ww.show.window"]
        let play = app.buttons["alignment.waveforms.transport.play"]
        let zoom = app.sliders["alignment.waveforms.zoom"]
        func assertDockedControls() {
            for control in [play, zoom, primary] {
                XCTAssertTrue(control.exists && control.isHittable,
                              "Timeline controls stay directly reachable with either bottom pane open.")
                XCTAssertTrue(window.frame.contains(control.frame),
                              "Bottom pane layout must not move controls outside the episode window.")
            }
        }
        assertDockedControls()
        let dockedY = play.frame.minY
        let review = app.buttons["ww.review.toggle"]
        review.click()
        XCTAssertTrue(wait { review.value as? String == "Hidden" })
        assertDockedControls()
        XCTAssertEqual(play.frame.minY, dockedY, accuracy: 1)
        review.click()
        XCTAssertTrue(wait { review.value as? String == "Shown" })
        assertDockedControls()
        XCTAssertEqual(play.frame.minY, dockedY, accuracy: 1)
        app.buttons["ww.mixer.toggle"].click()
        assertDockedControls()
        XCTAssertEqual(play.frame.minY, dockedY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = minimumSize ? "Minimum window sidebar activities and listening presets" : "Default window sidebar activities"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launch(minimumSize: Bool = false, singlePrimary: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Controls Sidebar Fixture",
            "-WWUITestShowFolder", "WWUITests-ControlsSidebar-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES",
        ]
        if minimumSize { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        if singlePrimary { app.launchArguments += ["-WWUITestSinglePrimaryFixture", "YES"] }
        app.launch()
        app.activate()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollID: String = "ww.alignment.workspace") {
        let scroll = app.scrollViews[scrollID]
        for _ in 0..<16 {
            if element.isHittable { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? 200 : -200)
        }
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [condition], timeout: 5) == .completed
    }
}
