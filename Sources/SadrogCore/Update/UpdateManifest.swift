// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CryptoKit

/// `update.json` published at https://gordas.dev/sadrog/update.json. Fields are only ever ADDED (a published version may decode any of them).
public struct UpdateManifest: Decodable, Equatable, Sendable {
    public static let url = URL(string: "https://gordas.dev/sadrog/update.json")!
    public let version: String
    public let build: String?
    public let changes: [String: String]
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64?
    public let mandatory: Bool

    enum K: String, CodingKey { case version, build, changes, download_url, sha256, size, mandatory }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decodeIfPresent(String.self, forKey: .build)
        if let m = try? c.decode([String: String].self, forKey: .changes) { changes = m }
        else { changes = (try? c.decode(String.self, forKey: .changes)).map { ["ro": $0] } ?? [:] }
        let mac: String
        if let m = try? c.decode([String: String].self, forKey: .download_url), let s = m["mac"] { mac = s } else { mac = try c.decode(String.self, forKey: .download_url) }
        guard let u = URL(string: mac), u.scheme == "https", u.host == "gordas.dev" || u.host == "github.com" else {
            throw DecodingError.dataCorruptedError(forKey: .download_url, in: c, debugDescription: "download_url must be https on gordas.dev or github.com")
        }
        downloadURL = u
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: c, debugDescription: "sha256")
        }
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        mandatory = try c.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
    }
    public func notes(_ lang: AppLanguage = .current) -> String { changes[lang.rawValue] ?? changes["en"] ?? changes["ro"] ?? "" }
    /// Strictly newer than the installed version (equal or older is never offered).
    public func isNewer(than installed: String) -> Bool { Self.compare(version, installed) > 0 }

    public static func compare(_ a: String, _ b: String) -> Int {
        func p(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let x = p(a), y = p(b)
        for i in 0..<max(x.count, y.count) { let u = i < x.count ? x[i] : 0, v = i < y.count ? y[i] : 0; if u != v { return u > v ? 1 : -1 } }
        return 0
    }
    /// SHA-256 of a downloaded file, streamed (no whole-file read).
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
