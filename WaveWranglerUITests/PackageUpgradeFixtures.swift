import Foundation
import WWCore
import WWPersistence

enum PackageUpgradeFixtures {
    static var unknownChannels: Data { get throws { try make(title: "Unknown Channel Show", channels: [nil]) } }
    static var statedChannels: Data { get throws { try make(title: "Stated Show", channels: [1, 0]) } }
    static var mixed: Data { get throws { try make(title: "Mixed Show", channels: [nil, 1]) } }

    private static func make(title: String, channels: [Int?]) throws -> Data {
        let source = SourceRecord(displayNameHint: "synthetic-0.wav",
                                  observations: .init(channelCount: .known(2)))
        let speakers = channels.indices.map { Speaker(name: "Speaker \($0 + 1)") }
        let assignments = zip(speakers, channels).map {
            SpeakerAssignment(speakerID: $0.0.id,
                primary: ChannelReference(sourceID: source.id, statedChannel: $0.1),
                primaryConfirmation: .userConfirmed)
        }
        let model = ShowDocumentModel(show: Show(title: title), speakers: speakers,
            episodes: [Episode(title: "Generated Episode", sources: [source], speakerAssignments: assignments)])
        return try ShowPackageCoder().encode(model, revision: 1)
    }
}
