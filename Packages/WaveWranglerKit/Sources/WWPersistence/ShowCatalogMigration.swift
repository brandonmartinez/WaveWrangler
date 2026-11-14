import Foundation
import WWCore

extension DocumentMigrator where Coder == ShowCatalogCoder {
    /// Explicit version-1 package upgrade, retaining exact originals before publication.
    /// Register future package/model upgrades here with independent expectations. The shared migrator
    /// owns consent-time base checks, nonoverwriting backups and verified publication.
    public static func show(publisher: DocumentPublisher<ShowCatalogCoder>) -> Self {
        let step = MigrationStep<ShowCatalog>(fromSchema: SchemaVersion.show, migrate: { original in
            guard try ShowPackage.storageVersion(of: original) == 1 else {
                throw PersistenceError.malformed("Expected a version-1 show package")
            }
            let decoded = try ShowPackageCoder().decode(original)
            return (try ShowCatalog(decoded.payload), decoded.revision)
        }, expectations: { original, catalog in
            do {
                let before = try ShowPackageCoder().decode(original).payload
                let after = try catalog.materializedModel()
                return before == after ? [] : ["Indexed package conversion changed document content"]
            } catch {
                return ["Cannot independently verify the indexed package conversion: \(error.localizedDescription)"]
            }
        })
        return Self(publisher: publisher, steps: [step],
            identify: { (try? ShowPackageCoder().decode($0)).map { .show($0.payload.show.id) } })
    }
}
