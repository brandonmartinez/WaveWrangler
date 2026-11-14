import Foundation
import WWCore
@testable import WWPersistence

// Exercises the format-independent envelope/publication protocol with a rich synthetic payload.
// This identifier is not a supported show document format.
extension JSONEnvelopeCoder where Payload == ShowDocumentModel {
    static var fixture: Self {
        Self(format: DocumentFormat(identifier: "com.brandonmartinez.wavewrangler.persistence-test",
            filenameExtension: nil, currentSchemaVersion: SchemaVersion.show,
            minimumReadableSchemaVersion: SchemaVersion.show),
            newerContent: { $0.newerEmbeddedTimeMapSchema() }) {
                $0.validationIssues(expectedSchemaVersion: $1) + $0.embeddedMapIssues()
            }
    }
}

extension DocumentOpener where Coder == JSONEnvelopeCoder<ShowDocumentModel> {
    static func fixture(ops: any FileOperations = LocalFileOperations(),
                        coordination: any FileCoordinating = NSFileCoordination(),
                        recovery: RecoveryStore?) -> Self {
        Self(coder: .fixture, ops: ops, coordination: coordination, recovery: recovery,
             identityOf: { .show($0.show.id) })
    }
}
