import Darwin
import Foundation

/// A bounded local, per-volume identity for the item opened at an originating URL. It is not a
/// provider transaction witness: a provider may still change the item after the pre-write check.
public struct FileItemIdentity: Sendable, Equatable {
    private let device: UInt64
    private let inode: UInt64

    public static func observe(at url: URL) -> FileItemIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey]),
              values.volumeIsLocal == true, values.isUbiquitousItem != true else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_ino != 0 else { return nil }
        return FileItemIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
