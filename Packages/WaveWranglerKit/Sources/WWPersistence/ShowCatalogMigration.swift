import Foundation
import WWCore

extension DocumentMigrator where Coder == ShowCatalogCoder {
    /// Explicit legacy-envelope/episode-package upgrade, retaining exact originals before publication.
    public static func show(publisher: DocumentPublisher<ShowCatalogCoder>) -> Self {
        var steps = ShowSchemaMigration.steps.map { step in
            MigrationStep<ShowCatalog>(fromSchema: step.fromSchema, migrate: { original in
                let migrated = try step.migrate(original)
                return (try ShowCatalog(migrated.payload), migrated.originalRevision)
            }, expectations: { original, catalog in
                do { return step.expectations(original, try catalog.materializedModel()) }
                catch { return ["Cannot independently verify migrated episodes: \(error.localizedDescription)"] }
            })
        }
        steps.append(MigrationStep(fromSchema: SchemaVersion.show, migrate: { original in
            guard try ShowPackage.storageVersion(of: original) != 2 else {
                throw PersistenceError.malformed("This show already uses indexed package storage")
            }
            let decoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(original)
            return (try ShowCatalog(decoded.payload), decoded.revision)
        }, expectations: { original, catalog in
            do {
                let before = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(original).payload
                let after = try catalog.materializedModel()
                return before == after ? [] : ["Indexed package conversion changed document content"]
            } catch {
                return ["Cannot independently verify the indexed package conversion: \(error.localizedDescription)"]
            }
        }))
        return Self(publisher: publisher, steps: steps,
            identify: { (try? ShowSchemaMigration.decodeUpgradingOlder($0)).map { .show($0.payload.show.id) } })
    }
}
