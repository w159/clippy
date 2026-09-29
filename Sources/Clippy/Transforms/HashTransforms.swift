import CryptoKit
import Foundation

/// MD5, SHA-1, SHA-256 and SHA-512 hex digests of the UTF-8 text.
enum HashTransforms {
    /// Every hash transform.
    static let all: [any TextTransform] = [
        make("hash.md5", "MD5") { hex(Insecure.MD5.hash(data: $0)) },
        make("hash.sha1", "SHA-1") { hex(Insecure.SHA1.hash(data: $0)) },
        make("hash.sha256", "SHA-256") { hex(SHA256.hash(data: $0)) },
        make("hash.sha512", "SHA-512") { hex(SHA512.hash(data: $0)) }
    ]

    private static func make(_ id: String, _ title: String, _ body: @escaping @Sendable (Data) -> String) -> any TextTransform {
        FunctionTransform(id: id, title: title, category: .hash, keywords: ["hash", "digest", "checksum"]) { body(Data($0.utf8)) }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
