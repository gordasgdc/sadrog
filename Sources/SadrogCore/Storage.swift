// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

public enum StorageError: Error, Equatable {
    case destinationMissing(String)
    case notWritable(String)
    case notEnoughSpace(requiredBytes: Int64, availableBytes: Int64)
}

/// A user-chosen recording destination. Never silently falls back to another disk.
public struct Destination: Sendable, Equatable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func availableBytes() throws -> Int64 {
        let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Throws if the folder is gone (e.g. disk unplugged), unwritable, or lacks `requiredBytes`.
    public func validate(requiredBytes: Int64 = 0) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageError.destinationMissing(url.path)
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw StorageError.notWritable(url.path) }
        let free = try availableBytes()
        guard free >= requiredBytes else { throw StorageError.notEnoughSpace(requiredBytes: requiredBytes, availableBytes: free) }
    }
}
