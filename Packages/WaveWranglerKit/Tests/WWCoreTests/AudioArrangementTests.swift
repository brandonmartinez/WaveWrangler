import Foundation
import Testing
import WWCore

@Suite("Supplemental audio domain")
struct AudioArrangementTests {
    struct Fixture {
        let recording = SourceRecord(displayNameHint: "Generated recording")
        let asset = SourceRecord(displayNameHint: "Generated stereo asset",
            observations: .init(durationSeconds: .known(2), channelCount: .known(2), sampleRate: .known(44_100)),
            purpose: .supplementalAudio)
        let track = AudioTrack(name: "Music")
        let episode = EpisodeID()
        var facts: AudioAsset { .init(source: asset.id, frameCount: 88_200, sampleRate: 44_100, channelCount: 2) }
        var clip: AudioClip {
            .init(track: track.id, source: asset.id, trim: .init(startFrame: 0, endFrame: 88_200),
                  anchor: .programOrigin(frame: 0))
        }
        var arrangement: AudioArrangement { .init(assets: [facts], tracks: [track], clips: [clip]) }
        var show: ShowDocumentModel {
            .init(show: Show(title: "Synthetic"), episodes: [
                Episode(id: episode, title: "Episode", sources: [recording, asset])
            ])
        }
        func installed() throws -> ShowDocumentModel {
            try show.settingAudioArrangement(arrangement, in: episode)
        }
    }

    @Test func oldAbsenceIsRecordingAndNewAssetsShareOneIdentity() throws {
        let f = Fixture(), episode = f.show.episodes[0]
        #expect(episode.alignmentSources == [f.recording])
        #expect(episode.supplementalAudioSources == [f.asset])
        #expect(episode.sources(inRecorderGroup: nil) == [f.recording])
        #expect(episode.sources.count == 2)
        #expect(f.show.episodes[0].audioArrangement == nil)
        let recordingBytes = try JSONEncoder().encode(f.recording)
        #expect(!String(decoding: recordingBytes, as: UTF8.self).contains("purpose"))
        #expect(try JSONDecoder().decode(SourceRecord.self, from: recordingBytes).isRecording)
        var arrangement = f.arrangement
        let first = arrangement.clips[0]
        var second = first
        second.id = AudioClipID()
        second.anchor = .absolute(frame: 96_000)
        arrangement.clips.append(second)
        let model = try f.show.settingAudioArrangement(arrangement, in: f.episode)
        #expect(model.validationIssues().isEmpty)
        #expect(model.episodes[0].audioArrangement?.assets.count == 1)
        #expect(model.episodes[0].audioArrangement?.clips.map(\.source) == [f.asset.id, f.asset.id])
        #expect(model.episodes[0].audioArrangement?.clips[0].channels == nil)
        #expect(first.durationFrames(asset: f.facts) == 96_000)
        #expect(try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test func assetsCannotAcquireRecorderOrSpeakerRoles() throws {
        let f = Fixture()
        let speaker = Speaker(name: "Speaker")
        let group = RecorderGroup(name: "Recorder", epochs: [.init(label: "1")])
        var model = f.show
        model.speakers = [speaker]
        model.episodes[0].recorderGroups = [group]
        let channel = ChannelReference(sourceID: f.asset.id, statedChannel: 0)
        #expect(throws: DomainError.self) {
            try model.assigningSources([f.asset.id], toRecorderGroup: group.id, in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try model.settingSourceRole(.primary, confirmation: .userConfirmed, source: f.asset.id, in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try model.assigningPrimary(channel, to: speaker.id, in: f.episode, confirmation: .userConfirmed)
        }
        #expect(throws: DomainError.self) { try model.addingBackup(channel, to: speaker.id, in: f.episode) }
        #expect(throws: DomainError.self) {
            try model.assigningSpeaker(speaker.id, toSource: f.asset.id, in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try model.settingStatedChannel(0, forSource: f.asset.id, in: f.episode)
        }
        #expect(throws: DomainError.self) { try model.settingInputGain(3, for: channel, in: f.episode) }
        var corrupt = model
        corrupt.episodes[0].sources[1].placement.recorderGroupID = group.id
        #expect(corrupt.validationIssues().contains { $0.code == .invalidSourcePurpose })
        corrupt = model
        corrupt.episodes[0].speakerAssignments = [.init(speakerID: speaker.id, primary: channel)]
        #expect(corrupt.validationIssues().contains { $0.code == .invalidSourcePurpose })
        #expect(!EpisodePlaybackState().isAudible(f.asset.id, in: model.episodes[0]))
        #expect(EpisodePlaybackState().audibleSources(in: model.episodes[0]) == [f.recording.id])
    }

    @Test func atomicEditsDeletionAndExplicitSourceRemovalKeepMediaAndOtherState() throws {
        let f = Fixture(), original = try f.installed()
        let clip = try #require(original.episodes[0].audioArrangement?.clips.first)
        #expect(throws: DomainError.sourceUsedByAudioClips(f.asset.id)) {
            try original.removingSource(f.asset.id, from: f.episode)
        }
        var changed = clip
        changed.envelope = .init(points: [.init(frame: 0, amplitude: 1), .init(frame: 48_000, amplitude: 0)])
        let edited = try original.replacingAudioClip(changed, in: f.episode)
            .settingAudioTrackMix(.init(track: f.track.id, gainDB: -4, balance: 0.25), in: f.episode)
        #expect(edited.episodes[0].sources == original.episodes[0].sources)
        #expect(edited.history == original.history, "The shared store, not pure operations, registers Undo.")
        let removed = try edited.removingAudioTrack(f.track.id, in: f.episode)
        #expect(removed.episodes[0].audioArrangement?.clips.isEmpty == true)
        #expect(removed.episodes[0].mix?.audioTracks?.isEmpty == true)
        #expect(removed.episodes[0].sources == original.episodes[0].sources)
        let sourceRemoved = try removed.removingSource(f.asset.id, from: f.episode)
        #expect(sourceRemoved.episodes[0].audioArrangement?.assets.isEmpty == true)
        let compound = try edited.settingAudioState(nil, mix: nil, sources: [f.recording], in: f.episode)
        #expect(compound.validationIssues().isEmpty)
        #expect(compound.episodes[0].sources == [f.recording])
        #expect(edited.episodes[0].audioArrangement?.clips == [changed])
        #expect(throws: DomainError.self) {
            try edited.settingAudioState(edited.episodes[0].audioArrangement, mix: edited.episodes[0].mix,
                sources: [f.asset], in: f.episode)
        }
    }

    @Test(arguments: [
        "track", "source", "recording", "duplicateTrack", "duplicateClip", "duplicateAsset", "trimNegative",
        "trimEmpty", "trimOverflow", "sourceRate", "sourceFrames", "channel", "duplicateChannel", "emptyChannels",
        "anchor", "pointOrder", "pointDuplicate", "pointBounds", "pointNaN", "pointGain", "missingMap",
        "missingRegion", "nestedRegion", "regionOverflow", "duplicateRegion", "observedFrameMismatch"
    ])
    func malformedWholeValuesAreRefused(_ damage: String) throws {
        let f = Fixture()
        var a = f.arrangement
        switch damage {
        case "track": a.clips[0].track = AudioTrackID()
        case "source": a.clips[0].source = SourceID()
        case "recording": a.assets[0].source = f.recording.id; a.clips[0].source = f.recording.id
        case "duplicateTrack": a.tracks.append(a.tracks[0])
        case "duplicateClip": a.clips.append(a.clips[0])
        case "duplicateAsset": a.assets.append(a.assets[0])
        case "trimNegative": a.clips[0].trim.startFrame = -1
        case "trimEmpty": a.clips[0].trim.endFrame = 0
        case "trimOverflow": a.clips[0].trim.endFrame = .max
        case "sourceRate": a.assets[0].sampleRate = .max
        case "sourceFrames": a.assets[0].frameCount = .max
        case "observedFrameMismatch": a.assets[0].frameCount -= 1
        case "channel": a.clips[0].channels = [2]
        case "duplicateChannel": a.clips[0].channels = [0, 0]
        case "emptyChannels": a.clips[0].channels = []
        case "anchor": a.clips[0].anchor = .absolute(frame: .max)
        case "pointOrder": a.clips[0].envelope.points = [.init(frame: 2, amplitude: 1), .init(frame: 1, amplitude: 0)]
        case "pointDuplicate": a.clips[0].envelope.points = [.init(frame: 0, amplitude: 1), .init(frame: 0, amplitude: 0)]
        case "pointBounds": a.clips[0].envelope.points = [.init(frame: 96_001, amplitude: 0)]
        case "pointNaN": a.clips[0].envelope.points = [.init(frame: 0, amplitude: .nan)]
        case "pointGain": a.clips[0].envelope.points = [.init(frame: 0, amplitude: 1.01)]
        case "missingMap":
            a.clips[0].anchor = .dialogue(.init(alignmentRevision: 1, mapIdentity: String(repeating: "a", count: 64), frame: 0))
        case "missingRegion": a.clips[0].anchor = .insertion(region: AudioInsertionRegionID(), offsetFrames: 0)
        case "nestedRegion":
            let region = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 48_000)
            a.insertionRegions = [region, .init(anchor: .insertion(region: region.id, offsetFrames: 0), durationFrames: 1)]
        case "regionOverflow": a.insertionRegions = [.init(anchor: .absolute(frame: 0), durationFrames: .max)]
        case "duplicateRegion":
            let region = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 48_000)
            a.insertionRegions = [region, region]
        default: Issue.record("Unknown synthetic damage")
        }
        #expect(throws: DomainError.self) { try f.show.settingAudioArrangement(a, in: f.episode) }
        #expect(f.show.episodes[0].audioArrangement == nil)
    }

    @Test func sourceFactsChannelsMixAndCrossEpisodeOwnershipAreValidated() throws {
        let f = Fixture(), installed = try f.installed()
        #expect(throws: DomainError.self) {
            try installed.recordingMediaObservations(.init(channelCount: .known(1)), source: f.asset.id, in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try installed.recordingMediaObservations(.init(durationSeconds: .known(1)), source: f.asset.id, in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try installed.recordingMediaObservations(.init(sampleRate: .known(48_000)), source: f.asset.id, in: f.episode)
        }
        var other = installed
        other.episodes.append(Episode(title: "Other", audioArrangement: f.arrangement))
        #expect(!other.validationIssues().isEmpty)
        #expect(throws: DomainError.self) {
            try installed.addingEpisode(Episode(title: "Other", audioArrangement: f.arrangement))
        }
        #expect(throws: DomainError.self) {
            try installed.addingSource(f.asset, to: f.episode)
        }
        let effect = AudioUnitSlot(component: .init(type: 0x61756678, subtype: 1, manufacturer: 1))
        for state in [AudioTrackMixState(track: f.track.id, gainDB: .infinity),
                      .init(track: f.track.id, balance: 2)] {
            #expect(throws: DomainError.self) { try installed.settingAudioTrackMix(state, in: f.episode) }
        }
        #expect(throws: DomainError.self) {
            try installed.settingMix(.init(master: .init(inserts: [effect]),
                audioTracks: [.init(track: f.track.id, inserts: [effect])]), in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try installed.settingMix(.init(audioTracks: [.init(track: AudioTrackID())]), in: f.episode)
        }
        #expect(throws: DomainError.self) {
            try installed.settingMix(.init(audioTracks: [.init(track: f.track.id), .init(track: f.track.id)]), in: f.episode)
        }
    }

    @Test func assetsAndPlacementNeverChangeRecordingInputsButActualProductionEditsDo() throws {
        let f = Fixture()
        var before = f.show
        before.episodes[0].sources.removeLast()
        #expect(before.hasSameMediaInputs(as: f.show, in: f.episode))
        #expect(before.hasSameProcessingInputs(as: f.show, in: f.episode))
        let installed = try f.installed()
        #expect(installed.hasSameMediaInputs(as: before, in: f.episode, includingWorkingRange: true))
        #expect(!installed.hasSameProcessingInputs(as: before, in: f.episode))
        let clip = try #require(installed.episodes[0].audioArrangement?.clips.first)
        for edit in ["placement", "trim", "envelope", "channels", "assetFacts", "mix"] {
            var changed = installed
            switch edit {
            case "placement": changed.episodes[0].audioArrangement?.clips[0].anchor = .absolute(frame: 48_000)
            case "trim": changed.episodes[0].audioArrangement?.clips[0].trim.startFrame = 44_100
            case "envelope": changed.episodes[0].audioArrangement?.clips[0].envelope.points = [.init(frame: 0, amplitude: 0)]
            case "channels": changed.episodes[0].audioArrangement?.clips[0].channels = [1, 0]
            case "assetFacts": changed.episodes[0].sources[1].observations.durationSeconds = .unknown
            case "mix": changed = try changed.settingAudioTrackMix(.init(track: clip.track, gainDB: -3), in: f.episode)
            default: Issue.record("Unknown processing change")
            }
            #expect(changed.hasSameMediaInputs(as: installed, in: f.episode))
            #expect(!changed.hasSameProcessingInputs(as: installed, in: f.episode))
            #expect(EpisodeProcessingInputs(changed.episodes[0]).hasSameProgramInputs(
                as: EpisodeProcessingInputs(installed.episodes[0])) == (edit == "mix"))
        }
        let renamed = try installed.replacingAudioTrack(.init(id: f.track.id, name: "Renamed"), in: f.episode)
        #expect(renamed.hasSameProcessingInputs(as: installed, in: f.episode))
    }

    @Test func anchorsRetainExactDurableMapIdentityAndAllowAudioOnlyOrigins() throws {
        var episode = Fixture().show.episodes[0]
        let first = TimeMapVersion(revision: 1, inputs: .init(sources: []), map: .number(0.0))
        let anchor = try AudioDialogueAnchor(map: first, frame: 48_000)
        episode.alignment = .init(maps: [first], acceptedRevision: 1)
        #expect(try anchor.isCurrent(in: episode))
        var recreated = try JSONDecoder().decode(TimeMapVersion.self, from: JSONEncoder().encode(first))
        #expect(try AudioDialogueAnchor.identity(of: recreated) == anchor.mapIdentity)
        recreated.map = .number(-0.0)
        #expect(recreated == first)
        episode.alignment?.maps[0] = recreated
        #expect(try !anchor.isCurrent(in: episode))
        #expect(try Fixture().installed().validationIssues().isEmpty)
    }

    @Test func mixerReplacementClassificationCapturesProgramAndInsertsButNotLiveLevels() throws {
        let f = Fixture(), speaker = Speaker(name: "Synthetic speaker")
        let model = try f.installed().addingSpeaker(speaker, toEpisode: f.episode)
        let before = EpisodeProcessingInputs(model.episodes[0])
        let live = try model.settingAudioTrackMix(.init(track: f.track.id, gainDB: -6, balance: 0.5), in: f.episode)
            .settingSpeakerMix(.init(speaker: speaker.id, gainDB: -8, pan: -0.5), in: f.episode)
            .settingMasterMix(.init(gainDB: -3), in: f.episode)
            .settingInputGain(4, for: .init(sourceID: f.recording.id, statedChannel: 0), in: f.episode)
        #expect(before.hasSameMixerTopology(as: EpisodeProcessingInputs(live.episodes[0])))
        #expect(before != EpisodeProcessingInputs(live.episodes[0]))
        let effect = AudioUnitSlot(component: .init(type: 0x61756678, subtype: 1, manufacturer: 1))
        let trackInsert = try model.settingAudioTrackMix(.init(track: f.track.id, inserts: [effect]), in: f.episode)
        let masterInsert = try model.settingMasterMix(.init(inserts: [effect]), in: f.episode)
        let speakerInsert = try model.settingSpeakerMix(.init(speaker: speaker.id, inserts: [effect]), in: f.episode)
        var moved = model
        moved.episodes[0].audioArrangement?.clips[0].anchor = .absolute(frame: 48_000)
        var faded = model
        faded.episodes[0].audioArrangement?.clips[0].envelope.points = [.init(frame: 0, amplitude: 0)]
        var changedAsset = model
        changedAsset.episodes[0].sources[1].observations.durationSeconds = .unknown
        for replacement in [trackInsert, speakerInsert, masterInsert, moved, faded, changedAsset] {
            #expect(!before.hasSameMixerTopology(as: EpisodeProcessingInputs(replacement.episodes[0])))
        }
        let renamed = try model.replacingAudioTrack(.init(id: f.track.id, name: "Display rename"), in: f.episode)
        #expect(before.hasSameMixerTopology(as: EpisodeProcessingInputs(renamed.episodes[0])))
        #expect(before.hasSameMixerTopology(as: before))
    }
}
