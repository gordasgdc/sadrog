import Foundation

/// Working folder for tests that need scratch space or generated media.
/// Override with SADROG_TEST_ROOT; defaults to a folder under the system temporary directory.
enum TestRoot {
    static let path: String = {
        let p = ProcessInfo.processInfo.environment["SADROG_TEST_ROOT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("sadrog-tests")
        for sub in ["", "temp", "synthetic"] {
            try? FileManager.default.createDirectory(atPath: sub.isEmpty ? p : p + "/" + sub, withIntermediateDirectories: true)
        }
        return p
    }()
}
