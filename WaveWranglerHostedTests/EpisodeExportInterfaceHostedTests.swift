import AppKit
import AVFAudio
import Foundation
import ImageIO
import Testing
import WWCore
import WWDecode
import WWExport
import WWMix
import WWOrganizer
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Native episode export interface", .serialized)
struct EpisodeExportInterfaceHostedTests {
    private func document() throws -> (ShowDocument, EpisodeID) {
        let episode = Episode(title: "Synthetic episode", number: 7)
        let model = ShowDocumentModel(show: .init(title: "Synthetic show",
            publication: .init(creator: "Show artist", publisher: "Publisher")), episodes: [episode])
        let document = ShowDocument()
        try document.read(from: JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            model, revision: 1, publicationID: UUID()).data, ofType: "com.brandonmartinez.wavewrangler.show")
        return (document, episode.id)
    }

    @MainActor
    @Suite("Whole-episode production export qualification (synthetic only)", .serialized)
    struct EpisodeExportProductionHostedTests {
        private func ready() async throws -> AlignmentWaveformRetentionHostedTests.Fixture {
            let fixture = try await MixerHostedTests().ready(durationSeconds: 8)
            let episode = try #require(fixture.document.store.model.episode(fixture.model.episodeID))
            let revision = try #require(episode.alignment?.acceptedRevision)
            let slot = try MixerHostedTests().appleSlot()
            let clipURL = fixture.folder.appendingPathComponent("generated-clip.caf")
            try SupplementalProductionHostedTests.writeAudio(clipURL)
            let source = SourceRecord(displayNameHint: "Generated export clip", purpose: .supplementalAudio)
            let io = SystemSourceIO()
            guard case .success(let metadata) = io.metadata(at: clipURL) else { throw DecodeFailure.notFound }
            let witness = try await SourceDecoder(access: .init(io: io)).captureRawIdentity(
                clipURL, matching: metadata.fingerprint)
            let access = FileDeviceAccessStore(fileURL: fixture.folder.appendingPathComponent("access.json"))
            try await access.save(.init(showID: fixture.document.store.model.show.id, sourceID: source.id,
                bookmark: try io.makeReadOnlyBookmark(for: clipURL), lastKnownPath: clipURL.path,
                recordedIdentity: .init(fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                    recordedAt: Date(), rawWitness: witness), createdAt: Date()))
            let track = AudioTrack(name: "Export clip")
            let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try #require(context.makeImage())
            let artworkBytes = NSMutableData()
            let imageDestination = try #require(CGImageDestinationCreateWithData(
                artworkBytes, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(imageDestination, image, nil)
            try #require(CGImageDestinationFinalize(imageDestination))
            let artwork = try PublicationArtwork(data: artworkBytes as Data)
            let arrangement = AudioArrangement(
                assets: [.init(source: source.id, frameCount: 4800, sampleRate: 48_000, channelCount: 2)],
                tracks: [track], clips: [.init(track: track.id, source: source.id,
                    trim: .init(startFrame: 0, endFrame: 4800), anchor: .absolute(frame: 12_000),
                    envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 4800, amplitude: 1)]))])
            try #require(fixture.document.store.apply("Prepare export production") { model throws(DomainError) in
                let cut = ManualEpisodeCut(alignmentRevision: revision, startFrame: 48_000, endFrame: 96_000)
                let edited = try model.settingCleanup(.init(manualCuts: [cut]), in: episode.id)
                let bounded = try edited.settingProductionRange(.init(start: .absolute(frame: -24_000),
                    end: .absolute(frame: 264_003)), in: episode.id)
                let arranged = try bounded.settingAudioState(arrangement,
                    mix: .init(master: .init(gainDB: -6, inserts: [slot]),
                        audioTracks: [.init(track: track.id, gainDB: -3, balance: 1)]),
                    sources: episode.sources + [source], in: episode.id)
                return try arranged.settingShowPublication(.init(creator: "Synthetic caf\u{00E9}",
                    publicDescription: "Public generated description", genre: "Podcast", artwork: .image(artwork)))
            })
            try await MixerHostedTests().save(fixture.document)
            return .init(folder: fixture.folder, document: fixture.document, model: fixture.model,
                runtime: fixture.runtime, target: fixture.target, files: fixture.files + [clipURL])
        }

        private func selections(_ fixture: AlignmentWaveformRetentionHostedTests.Fixture,
                                prefix: String, normalization: ExportNormalization) throws -> [EpisodeExportDelivery] {
            let resolved = try fixture.document.store.model.resolvedPublication(for: fixture.model.episodeID)
            return try [
                ExportSettings(codec: .wave(.float32), sampleRate: 48_000, channels: 2),
                ExportSettings(codec: .mp3(.constantBitrate(kbps: 192)), sampleRate: 44_100, channels: 2),
                ExportSettings(codec: .aacLC(bitrate: 192_000), sampleRate: 48_000, channels: 2),
            ].map { settings in
                var delivery = EpisodeExportDelivery(filename: "\(prefix).\(settings.codec.fileExtension)", settings: settings)
                delivery.titleOverride = "Qualified production"
                delivery.overrides.genre = ""
                delivery.normalization = normalization
                delivery.confirmedOmissions = try ExportMetadataAdapter.preview(resolved, delivery: delivery).omissions
                return delivery
            }
        }

        private func decode(_ url: URL) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            let channels = try #require(buffer.floatChannelData)
            var result = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
            while file.framePosition < file.length {
                try file.read(into: buffer)
                try #require(buffer.frameLength > 0)
                for index in result.indices {
                    result[index].append(contentsOf: UnsafeBufferPointer(start: channels[index], count: Int(buffer.frameLength)))
                }
            }
            return result
        }

        @Test func generatedProductionExportsAllFormatsOffAndNormalizedWithCapturedNativeState() async throws {
            let f = try await ready()
            defer { f.close() }
            let originals = try f.files.map { try Data(contentsOf: $0) }
            let owner = MixerHostedTests().owner(f)
            let controller = f.model.mixer
            _ = try await controller.prepare(programFrames: -24_000..<264_003)
            let processor = try #require(controller.processor)
            let slot = try #require(f.document.store.model.episode(f.model.episodeID)?.mix?.master.inserts.first)
            let parameter = try #require(try await processor.parameters(slot: slot.id).first {
                $0.writable && $0.minimum < 1000 && $0.maximum > 1000
            })
            let beforeCapture = f.document.store.model
            try await processor.setParameter(slot: slot.id, address: parameter.address, value: 1000)
            var captured: [[AudioUnitSlotID]] = []
            controller.didCaptureNativeStates = { captured.append($0) }
            let folder = f.folder.appendingPathComponent("deliveries")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let off = try await f.document.exportJobs.run(episode: f.model.episodeID, runtime: f.runtime,
                userSelectedDirectory: folder, deliveries: selections(f, prefix: "Off", normalization: .off))
            try #require(off.succeeded, "\(String(describing: off.problem)) \(off.cleanupErrors)")
            #expect(off.published.count == 3 && captured.contains { $0.contains(slot.id) })
            let capturedModel = f.document.store.model
            #expect(capturedModel != beforeCapture, "Export must capture unpolled native fullState before freezing its recipe.")
            let stillPlaying = f.model.canStopAudition
            let retired = controller.processor == nil
            #expect(!stillPlaying && retired)

            let wave = try decode(folder.appendingPathComponent("Off.wav"))
            #expect(wave.count == 2 && wave[0].count == 288_003)
            #expect(wave[0].prefix(24_000).allSatisfy { $0 == 0 }, "Negative production preroll must not shift source audio.")
            #expect(wave[0].dropFirst(24_000).contains { abs($0) > 0.001 })
            let recipe = try await f.runtime.mixerRecipe(model: capturedModel, episode: f.model.episodeID,
                programFrames: -24_000..<264_003, policy: .init(tail: .truncate))
            let expected = ExportQualificationPCM()
            try await f.runtime.renderProductionOffline(recipe: recipe, model: capturedModel, isCurrent: { true }) {
                await expected.append($0.channels)
            }
            let reference = await expected.channels
            #expect(reference.count == 2 && reference[0].count == wave[0].count)
            let maximumError = zip(reference.flatMap { $0 }, wave.flatMap { $0 }).map { abs($0 - $1) }.max() ?? .infinity
            #expect(maximumError < 0.00001, "Off must preserve the actual production mix, cuts, effects and exact truncated range.")
            let artwork = try #require(capturedModel.resolvedPublication(for: f.model.episodeID).metadata.artwork?.image?.data)
            Attachment.record(artwork, named: "ExpectedArtwork.png")
            for receipt in off.published {
                let decoded = try decode(receipt.url)
                #expect(decoded.count == 2 && decoded.allSatisfy { $0.allSatisfy(\.isFinite) })
                #expect(receipt.loudness.targetStatus == .off && receipt.loudness.appliedGainDB == 0)
                let expectedFrames = Int64((288_003 * Double(receipt.settings.sampleRate) / 48_000).rounded())
                #expect(receipt.inputFrames == expectedFrames)
                #expect(abs(Int64(decoded[0].count) - expectedFrames) <= (receipt.url.pathExtension == "wav" ? 0 : 3072))
                let bytes = try Data(contentsOf: receipt.url)
                #expect((bytes.range(of: artwork) != nil) == (receipt.url.pathExtension != "wav"),
                        "Lossy formats embed the inherited original artwork; WAV must honor its confirmed omission.")
                Attachment.record(bytes, named: receipt.url.lastPathComponent)
            }

            let normalized = try await f.document.exportJobs.run(episode: f.model.episodeID, runtime: f.runtime,
                userSelectedDirectory: folder, deliveries: selections(f, prefix: "Podcast", normalization: .podcast))
            try #require(normalized.succeeded, "\(String(describing: normalized.problem)) \(normalized.cleanupErrors)")
            #expect(normalized.published.count == 3)
            for receipt in normalized.published {
                let peak = try #require(receipt.loudness.measurement.truePeakDBTP)
                let loudness = try #require(receipt.loudness.measurement.integratedLUFS)
                #expect(peak <= -1 && receipt.loudness.requestedTargetLUFS == -16)
                #expect(receipt.loudness.targetStatus != .off && receipt.loudness.targetStatus != .unmeasurable)
                print("EXPORT_PRODUCTION \(receipt.url.lastPathComponent) input=\(receipt.inputFrames) decoded=\(receipt.decodedFrames) LUFS=\(loudness) dBTP=\(peak) status=\(receipt.loudness.targetStatus)")
                Attachment.record(try Data(contentsOf: receipt.url), named: receipt.url.lastPathComponent)
            }
            #expect(f.document.store.model == capturedModel)
            #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
            #expect(owner.state.store === f.document.store)
            try await MixerHostedTests().save(f.document)
            let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: #require(f.document.fileURL))).payload
            #expect(reopened == capturedModel)
            try await controller.discardUncapturedEditorState()
        }

        @Test func realExportCancellationAndModelInvalidationPublishNothingAndReleaseTheJob() async throws {
            let f = try await ready()
            defer { f.close() }
            let folder = f.folder.appendingPathComponent("interrupted")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let deliveries = try selections(f, prefix: "Canceled", normalization: .podcast)
            let service = f.document.exportJobs
            let canceled = Task {
                try await service.run(episode: f.model.episodeID, runtime: f.runtime,
                    userSelectedDirectory: folder, deliveries: deliveries)
            }
            try await MixerHostedTests().wait("Running production export") { service.isRunning }
            await service.cancel()
            do {
                let result = try await canceled.value
                #expect(!result.succeeded && result.problem?.kind == .canceled && result.published.isEmpty)
            } catch is CancellationError {
                #expect(service.state == .canceled)
            }
            let canceledContents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(!service.isRunning && canceledContents.isEmpty)

            let stale = Task {
                try await service.run(episode: f.model.episodeID, runtime: f.runtime,
                    userSelectedDirectory: folder, deliveries: deliveries)
            }
            try await MixerHostedTests().wait("Production renderer admission") { service.state == .running }
            try #require(f.document.store.apply("Change production gain") { model throws(DomainError) in
                try model.settingMasterMix(.init(gainDB: -12), in: f.model.episodeID)
            })
            let invalidated = try await stale.value
            #expect(!invalidated.succeeded && invalidated.problem?.kind == .stale && invalidated.published.isEmpty)
            let invalidatedContents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(!service.isRunning && invalidatedContents.isEmpty)

            try await MixerHostedTests().save(f.document)
            let snapshot = f.document.store.model
            let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
            let source = try #require(snapshot.episode(f.model.episodeID)?.speakerAssignments.first?.primary?.sourceID)
            try await access.removeRecord(for: .init(showID: snapshot.show.id, sourceID: source))
            do {
                let refused = try await service.run(episode: f.model.episodeID, runtime: f.runtime,
                    userSelectedDirectory: folder, deliveries: deliveries)
                #expect(!refused.succeeded && refused.published.isEmpty)
            } catch {
                #expect(service.lastResult == nil && !service.isRunning)
            }
            #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty)
        }
    }

    private actor ExportQualificationPCM {
        var channels = [[Float]](repeating: [], count: 2)
        func append(_ block: [[Float]]) {
            for index in channels.indices { channels[index].append(contentsOf: block[index]) }
        }
    }

    @Test func legacyMenuToolbarStateSharesOneDocumentPresentationWithoutNavigation() throws {
        let (document, episode) = try document()
        defer { document.close() }
        let first = ShowWindowState(store: document.store, episodeID: episode)
        let second = ShowWindowState(store: document.store, episodeID: episode)
        let original = document.store.model
        #expect(first.exportUnavailableReason == nil)
        let destination = first.destination
        first.select(.export)
        let presentation = document.exportInterface
        let firstPresented = first.exportPresented
        #expect(firstPresented && presentation.episodeID == episode)
        #expect(first.destination == destination)
        #expect(second.exportUnavailableReason?.contains("another window") == true)
        second.requestExport()
        #expect(!second.exportPresented && first.exportPresented)
        let (other, otherEpisode) = try self.document()
        defer { other.close() }
        let otherState = ShowWindowState(store: other.store, episodeID: otherEpisode)
        #expect(otherState.exportUnavailableReason == nil)
        otherState.requestExport()
        #expect(otherState.exportPresented)
        presentation.dismiss()
        #expect(!first.exportPresented && second.exportUnavailableReason == nil)
        #expect(document.store.model == original)
        second.recordingsPresented = true
        #expect(second.exportUnavailableReason?.contains("Recordings") == true)
    }

    @Test func editsRevokeOmissionConsentSynchronouslyAndNeverEditTheShow() throws {
        let (document, episode) = try document()
        defer { document.close() }
        let state = ShowWindowState(store: document.store, episodeID: episode)
        state.requestExport()
        let presentation = document.exportInterface
        let original = document.store.model
        let omissions = try presentation.allOmissions
        #expect(!omissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.titleOverride = "Export title"
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.overrides.creator = ""
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.options.formats.insert(.mp3)
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.episodeNumberOverride = ""
        let selections = try presentation.selections()
        let preview = try #require(try presentation.previews.first { $0.format == .mp3 })
        #expect(preview.preview.metadata.title == "Export title")
        #expect(preview.preview.metadata.artist == nil && preview.preview.metadata.episodeNumber == nil)
        #expect(selections.count == 2 && document.store.model == original)
    }

    @Test func nativeMenuRoutesExportOnlyFromFileAndKeepsStandardAboutAndLicenses() throws {
        let windows = NSApp.windowsMenu, help = NSApp.helpMenu, services = NSApp.servicesMenu
        defer { NSApp.windowsMenu = windows; NSApp.helpMenu = help; NSApp.servicesMenu = services }
        let menu = MainMenu.make()
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
        let export = try #require(file.items.first { $0.action == #selector(CommandRouter.exportEpisode(_:)) })
        #expect(export.keyEquivalent == "4" && export.keyEquivalentModifierMask == .command)
        #expect(export.target === CommandRouter.shared)
        #expect(!view.items.contains { $0.title == "Export" || $0.keyEquivalent == "4" })
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items.contains { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) })
        let helpMenu = try #require(menu.items.first { $0.title == "Help" }?.submenu)
        #expect(helpMenu.items.contains { $0.action == #selector(CommandRouter.showSoftwareLicenses(_:)) })
    }

    @Test func actualAppAndPackageBundlesResolveAllSoftwareNotices() throws {
        let notices = try SoftwareLicenses.notices()
        #expect(notices.count == 6 && notices.allSatisfy { !$0.text.isEmpty })
        let whisperURL = try #require(Bundle.main.url(forResource: "WhisperCPULICENSE", withExtension: "txt"))
        #expect(notices.last?.text == (try String(contentsOf: whisperURL, encoding: .utf8)))
        #expect(notices.last?.text.contains("Jeffrey Quesnelle") == true)
        SoftwareLicensesWindowController.show()
        let window = try #require(NSApp.windows.first { $0.accessibilityIdentifier() == "ww.licenses.window" })
        #expect(window.contentMinSize.width >= 540 && window.title == "Software Licenses")
        window.close()
    }
}
