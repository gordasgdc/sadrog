// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

public enum StorageError: Error, Equatable {
    case destinationMissing(String)
    case notWritable(String)
    case notEnoughSpace(requiredBytes: Int64, availableBytes: Int64)
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationMissing(let p): return L10n.f("Folderul de destinație nu mai există sau discul nu este conectat: %@", p)
        case .notWritable(let p): return L10n.f("Nu se poate scrie în folderul de destinație: %@. Alege alt folder.", p)
        case .notEnoughSpace(let need, let free):
            return L10n.f("Spațiu insuficient la destinație: sunt liberi %@, sunt necesari cel puțin %@. Eliberează spațiu sau alege alt folder.", ByteCountFormatter.string(fromByteCount: free, countStyle: .file), ByteCountFormatter.string(fromByteCount: need, countStyle: .file))
        }
    }
}

/// A user-chosen recording destination. Never silently falls back to another disk.
public struct Destination: Sendable, Equatable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func availableBytes() throws -> Int64 {
        // "Important usage" capacity exists only on volumes that can purge (the APFS startup disk). External and network volumes report 0 or nothing
        // there although they have room, so the plain free capacity is the answer for them — otherwise every export to such a disk was refused.
        let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0, plain = Int64(v.volumeAvailableCapacity ?? 0)
        return max(important, plain)
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
