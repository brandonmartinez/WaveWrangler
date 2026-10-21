import CryptoKit
import Foundation

/// Maintenance pins are separate from historical qualification. A matching maintenance
/// tree must never authorize rerunning a holdout against a changed historical source.
public enum SourceTreeBaseline {
    public enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case missingRecord(String)
        case changedHistoricalRecord(String)
        case changedTreePaths(String)
        case changedHistoricalTree(String)
    }

    private struct Freeze: Decodable {
        let freezeID: String
        let pinnedTrees: [String: String]
    }

    private struct Manifest: Decodable {
        struct Record: Decodable {
            let historicalRecordSHA256: String
            let currentTrees: [String: String]
        }
        let version: Int
        let records: [String: Record]
    }

    public static func currentTrees(for freezeURL: URL) throws -> [String: String] {
        let data = try Data(contentsOf: freezeURL)
        let freeze = try JSONDecoder().decode(Freeze.self, from: data)
        let baselineURL = repository(for: freezeURL)
            .appending(path: "docs/engineering/source-tree-baselines.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: baselineURL))
        guard manifest.version == 1 else { throw Failure.unsupportedVersion(manifest.version) }
        guard let record = manifest.records[freeze.freezeID] else {
            throw Failure.missingRecord(freeze.freezeID)
        }
        guard hex(SHA256.hash(data: data)) == record.historicalRecordSHA256 else {
            throw Failure.changedHistoricalRecord(freeze.freezeID)
        }
        guard Set(record.currentTrees.keys) == Set(freeze.pinnedTrees.keys) else {
            throw Failure.changedTreePaths(freeze.freezeID)
        }
        return record.currentTrees
    }

    public static func requireHistoricalTrees(for freezeURL: URL) throws {
        let freeze = try JSONDecoder().decode(Freeze.self, from: Data(contentsOf: freezeURL))
        let package = repository(for: freezeURL).appending(path: "Packages/WaveWranglerKit")
        for (path, expected) in freeze.pinnedTrees {
            guard try gitTreeID(package.appending(path: path)) == expected else {
                throw Failure.changedHistoricalTree(path)
            }
        }
    }

    /// Git's flat regular-file tree format; edited and untracked files both change the ID.
    public static func gitTreeID(_ directory: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var body = Data()
        for name in names {
            let content = try Data(contentsOf: directory.appending(path: name))
            var blob = Data("blob \(content.count)\0".utf8)
            blob.append(content)
            body.append(Data("100644 \(name)\0".utf8))
            body.append(contentsOf: Insecure.SHA1.hash(data: blob))
        }
        var tree = Data("tree \(body.count)\0".utf8)
        tree.append(body)
        return hex(Insecure.SHA1.hash(data: tree))
    }

    private static func repository(for freezeURL: URL) -> URL {
        freezeURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
