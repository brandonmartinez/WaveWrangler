import Foundation
import Testing
import WWCore
import WWExport
import WWOrganizer

@Suite("Native episode export choices")
struct EpisodeExportSelectionTests {
    @Test func recommendedDefaultsAndFormatMatrixProduceTypedDeliveries() throws {
        var choices = EpisodeExportOptions()
        let wave = try choices.delivery(.wave, baseName: "Episode")
        #expect(wave.filename == "Episode.wav")
        #expect(wave.settings.codec == .wave(.int24))
        #expect(wave.settings.sampleRate == 48_000 && wave.settings.channels == 2)
        #expect(wave.normalization == .off && wave.dither == .none)
        let mp3 = try choices.delivery(.mp3, baseName: "Episode")
        #expect(mp3.settings.codec == .mp3(.constantBitrate(kbps: 192)))
        #expect(mp3.settings.sampleRate == 44_100)
        let aac = try choices.delivery(.m4a, baseName: "Episode")
        #expect(aac.settings.codec == .aacLC(bitrate: 192_000))
        #expect(aac.settings.sampleRate == 48_000)
        for channels in [1, 2] {
            choices.waveChannels = channels; choices.mp3Channels = channels; choices.aacChannels = channels
            for rate in [44_100, 48_000, 88_200, 96_000] {
                choices.waveRate = rate
                for bits in [16, 24, 32] {
                    choices.waveBits = bits
                    _ = try choices.delivery(.wave, baseName: "Synthetic")
                }
            }
            for rate in [44_100, 48_000] {
                choices.mp3Rate = rate; choices.aacRate = rate
                for bitrate in EpisodeExportOptions.mp3Bitrates {
                    choices.mp3Bitrate = bitrate
                    _ = try choices.delivery(.mp3, baseName: "Synthetic")
                }
                choices.mp3VBR = true
                for quality in 0...9 {
                    choices.mp3Quality = quality
                    _ = try choices.delivery(.mp3, baseName: "Synthetic")
                }
                choices.mp3VBR = false
                for bitrate in EpisodeExportOptions.aacBitrates {
                    choices.aacBitrate = bitrate
                    _ = try choices.delivery(.m4a, baseName: "Synthetic")
                }
            }
        }
    }

    @Test func ditherOnlyAppliesToIntegerWaveAndCustomTargetsAreValidated() throws {
        var choices = EpisodeExportOptions()
        choices.waveDither = true
        #expect(try choices.delivery(.wave, baseName: "Episode").dither == .tpdf)
        choices.waveBits = 32
        #expect(try choices.delivery(.wave, baseName: "Episode").dither == .none)
        #expect(try choices.delivery(.mp3, baseName: "Episode").dither == .none)
        #expect(try choices.delivery(.m4a, baseName: "Episode").dither == .none)
        choices.normalization = .custom
        for target in [-36.0, -9.0] {
            for ceiling in [-12.0, -0.1] {
                choices.targetLUFS = target; choices.ceilingDBTP = ceiling
                _ = try choices.delivery(.wave, baseName: "Episode")
            }
        }
        for target in [-36.1, -8.9, .nan, .infinity] {
            choices.targetLUFS = target
            #expect(throws: ExportFailure.self) { try choices.delivery(.wave, baseName: "Episode") }
        }
        choices.targetLUFS = -16
        for ceiling in [-12.1, 0.0, .nan, -.infinity] {
            choices.ceilingDBTP = ceiling
            #expect(throws: ExportFailure.self) { try choices.delivery(.mp3, baseName: "Episode") }
        }
    }

    @Test func corruptOrUnsupportedChoicesFailRatherThanCrashOrSilentlyConvert() throws {
        var choices = EpisodeExportOptions()
        for name in ["", " ", ".", "..", "Bad/Name", "Bad:Name", "Line\nBreak"] {
            #expect(throws: ExportFailure.self) { try choices.delivery(.wave, baseName: name) }
        }
        choices.aacBitrate = Int.max
        #expect(throws: ExportFailure.self) { try choices.validate() }
        choices = .init(); choices.mp3Rate = 96_000
        #expect(throws: ExportFailure.self) { try choices.validate() }
        choices = .init(); choices.aacRate = 88_200
        #expect(throws: ExportFailure.self) { try choices.validate() }
        choices = .init(); choices.mp3VBR = true; choices.mp3Quality = 10
        #expect(throws: ExportFailure.self) { try choices.validate() }
        choices = .init(); choices.formats = []
        #expect(throws: ExportFailure.self) { try choices.validate() }
        #expect(EpisodeExportOptions.suggestedBaseName(" ../Show: Episode\n1 ") == "..-Show- Episode-1")
        #expect(EpisodeExportOptions.suggestedBaseName("") == "Episode")
    }

    @Test func preferencesArePerShowAndOnlySuccessfulAttemptsReplaceThem() throws {
        let name = "WaveWrangler-ExportPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = EpisodeExportPreferenceStore(defaults: defaults, show: ShowID())
        let other = EpisodeExportPreferenceStore(defaults: defaults, show: ShowID())
        var choices = EpisodeExportOptions()
        choices.formats = [.wave, .mp3, .m4a]
        choices.normalization = .podcast
        try first.save(choices, directory: root, succeeded: false)
        #expect(try first.load() == nil)
        try first.save(choices, directory: root, succeeded: true)
        let restored = try #require(try first.load())
        #expect(restored.options == choices)
        #expect(restored.directory.standardizedFileURL == root.standardizedFileURL)
        #expect(try other.load() == nil)
        let bytes = defaults.dictionaryRepresentation()
        choices.waveBits = 16
        try first.save(choices, directory: root, succeeded: false)
        #expect(try first.load()?.options.waveBits == 24)
        #expect(defaults.dictionaryRepresentation() as NSDictionary == bytes as NSDictionary)
        let key = "WWEpisodeExport.v1.\(first.show)"
        defaults.set(Data("invalid choices".utf8), forKey: key)
        #expect(throws: (any Error).self) { try first.load() }
    }

    @Test func linkedLicenseResourcesResolveAndKeepUpstreamNotices() throws {
        let notices = try ExportLicensing.notices()
        #expect(notices.count == 5 && notices.allSatisfy { !$0.text.isEmpty })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #expect(notices.first { $0.id == "WaveWrangler-MIT.txt" }?.text ==
                (try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)))
        let source = root.appendingPathComponent("Packages/WaveWranglerKit/Sources/WWExport/Licenses")
        for name in ["COPYING", "LICENSE"] {
            #expect(notices.first { $0.id == name }?.text ==
                    (try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)))
        }
        let header = try #require(notices.first { $0.id == "LAME-Library-Notice.txt" }?.text)
        let upstream = try String(contentsOf: root.appendingPathComponent(
            "Packages/WaveWranglerKit/Sources/WWLameNative/upstream/libmp3lame/lame.c"), encoding: .utf8)
        #expect(upstream.hasPrefix(header))
        #expect(notices.first { $0.id == "COPYING" }?.text.contains("GNU LIBRARY GENERAL PUBLIC LICENSE") == true)
        #expect(notices.last?.text.contains("complete source rebuild/relink") == true)
    }

    @Test func legacyExportShortcutRemainsUniqueAndNavigationExplainsTheFileAction() {
        let shortcut = MenuCommand.destinationExport.shortcut
        #expect(shortcut == KeyShortcut("4"))
        #expect(MenuCommand.allCases.filter { $0.shortcut == shortcut } == [.destinationExport])
        #expect(!ShowDestination.export.isAvailableInThisVersion)
        #expect(ShowDestination.export.blockedPanel?.body.contains("File > Export") == true)
    }
}
