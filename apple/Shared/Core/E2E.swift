import CryptoKit
import Foundation

/// End-to-end encryption for relay mode — the Swift twin of
/// server/internal/e2e (see docs/relay-protocol.md).
enum E2E {
    static let segSize = 64 * 1024
    static let tagSize = 16
    static let nonceSize = 24
    static let headerSize = 84

    struct AuthError: LocalizedError {
        var errorDescription: String? { "数据校验失败（可能被篡改或密钥不匹配）" }
    }

    typealias Keyring = [UInt32: Data]

    static func opAAD(_ device: String, _ op: String) -> String { "fsop1|\(device)|\(op)" }
    static func replyAAD(_ device: String, _ op: String) -> String { "fsrp1|\(device)|\(op)" }
    static func keyringAAD(_ device: String) -> String { "fskr1|\(device)" }
    static func pairReqAAD(_ lookup: String) -> String { "fspq1|\(lookup)" }
    static func pairRespAAD(_ lookup: String) -> String { "fsps1|\(lookup)" }

    struct Envelope: Codable {
        let n: String
        let c: String
    }

    static func sealEnvelope(_ key: Data, _ plain: Data, aad: String) throws -> Envelope {
        let n = Data.random(nonceSize)
        let c = try XChaCha.seal(plain, key: key, nonce: n, aad: Data(aad.utf8))
        return Envelope(n: n.base64EncodedString(), c: c.base64EncodedString())
    }

    static func openEnvelope(_ key: Data, _ e: Envelope, aad: String) throws -> Data {
        guard let n = Data(base64Encoded: e.n), let c = Data(base64Encoded: e.c) else { throw AuthError() }
        do { return try XChaCha.open(c, key: key, nonce: n, aad: Data(aad.utf8)) } catch { throw AuthError() }
    }

    static func keyring(from j: [String: Any]) -> (Keyring, UInt32) {
        var ring = Keyring()
        for (k, v) in (j["keys"] as? [String: String]) ?? [:] {
            if let id = UInt32(k), let key = Data(base64Encoded: v) { ring[id] = key }
        }
        return (ring, UInt32((j["current"] as? NSNumber)?.uint32Value ?? 0))
    }

    static func pairing(secret: Data) -> (lookup: String, key: Data) {
        let salt = Data("fileswitch-pair".utf8)
        let l = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                       info: Data("lookup".utf8), outputByteCount: 16)
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                       info: Data("key".utf8), outputByteCount: 32)
        return (l.withUnsafeBytes { Data($0) }.hex, k.withUnsafeBytes { Data($0) })
    }

    static func cacheKey(_ spaceKey: Data, nodeID: String, sha: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("cache|\(nodeID)|\(sha)".utf8), using: SymmetricKey(data: spaceKey))
        return Data(mac).prefix(16).hex
    }

    static func cipherSize(_ size: Int64) -> Int64 {
        let n = max(1, (size + Int64(segSize) - 1) / Int64(segSize))
        return Int64(headerSize) + size + n * Int64(tagSize)
    }

    static func segNonce(_ i: Int64) -> Data {
        var n = Data(count: nonceSize)
        withUnsafeBytes(of: UInt64(i).bigEndian) { n.replaceSubrange(16..<24, with: $0) }
        return n
    }

    static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    /// Encrypts a local file for upload; any ciphertext range can be
    /// regenerated, so uploads resume wherever the relay left off.
    final class BlobEncryptor: @unchecked Sendable {
        let url: URL
        let size: Int64
        let header: Data
        private let fk: Data

        init(url: URL, size: Int64, kid: UInt32, spaceKey: Data) throws {
            self.url = url
            self.size = size
            fk = Data.random(32)
            let nonce = Data.random(E2E.nonceSize)
            let aad = Data("FSE1".utf8) + E2E.be32(kid)
            let wrapped = try XChaCha.seal(fk, key: spaceKey, nonce: nonce, aad: aad)
            header = Data("FSE1".utf8) + Data([1, 0, 0, 0]) + E2E.be32(kid) + nonce + wrapped
        }

        var length: Int64 { E2E.cipherSize(size) }
        var nonceB64: String { header.subdata(in: 12..<36).base64EncodedString() }

        func range(_ start: Int64, _ end: Int64) throws -> Data {
            precondition(start >= 0 && end <= length && start <= end)
            var out = Data()
            var pos = start
            let hs = Int64(E2E.headerSize)
            if pos < hs {
                out += header.subdata(in: Int(pos)..<Int(min(end, hs)))
                pos = hs
            }
            if pos >= end { return out }
            let nseg = max(1, (size + Int64(E2E.segSize) - 1) / Int64(E2E.segSize))
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            let segCT = Int64(E2E.segSize + E2E.tagSize)
            while pos < end {
                let i = (pos - hs) / segCT
                let segStart = hs + i * segCT
                let plainLen = Int(min(Int64(E2E.segSize), size - i * Int64(E2E.segSize)))
                try fh.seek(toOffset: UInt64(i) * UInt64(E2E.segSize))
                let plain = try fh.read(upToCount: plainLen) ?? Data()
                guard plain.count == plainLen else { throw CocoaError(.fileReadCorruptFile) }
                let ct = try XChaCha.seal(plain, key: fk, nonce: E2E.segNonce(i), aad: Data([i == nseg - 1 ? 1 : 0]))
                let to = min(Int64(ct.count), end - segStart)
                out += ct.subdata(in: Int(pos - segStart)..<Int(to))
                pos = segStart + to
            }
            return out
        }
    }

    private static func unwrap(_ hdr: Data, _ ring: Keyring) throws -> Data {
        guard hdr.count == headerSize, hdr.prefix(4) == Data("FSE1".utf8), hdr[hdr.startIndex + 4] == 1 else { throw AuthError() }
        let kid = hdr.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard let sk = ring[kid] else { throw AuthError() }
        do {
            return try XChaCha.open(hdr.subdata(in: 36..<84), key: sk, nonce: hdr.subdata(in: 12..<36),
                                    aad: Data("FSE1".utf8) + be32(kid))
        } catch { throw AuthError() }
    }

    /// Decrypts an FSE1 file into dst, verifying every segment and the
    /// plaintext SHA-256 the NAS recorded.
    static func decryptFile(src: URL, dst: URL, size: Int64, ring: Keyring, sha: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: src.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == cipherSize(size) else { throw AuthError() }
        let inp = try FileHandle(forReadingFrom: src)
        defer { try? inp.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let fk = try unwrap(try inp.read(upToCount: headerSize) ?? Data(), ring)
        let nseg = max(1, (size + Int64(segSize) - 1) / Int64(segSize))
        var hasher = SHA256()
        for i in 0..<nseg {
            let len = Int(min(Int64(segSize), size - i * Int64(segSize))) + tagSize
            let ct = try inp.read(upToCount: len) ?? Data()
            guard ct.count == len else { throw AuthError() }
            let pt: Data
            do { pt = try XChaCha.open(ct, key: fk, nonce: segNonce(i), aad: Data([i == nseg - 1 ? 1 : 0])) } catch { throw AuthError() }
            try out.write(contentsOf: pt)
            hasher.update(data: pt)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if !sha.isEmpty && digest != sha { throw AuthError() }
    }

    /// Opens an FSS1 snapshot: (version, plaintext JSON).
    static func openSnapshot(_ data: Data, spaceID: String, ring: Keyring) throws -> (UInt64, Data) {
        guard data.count > 16 + nonceSize, data.prefix(4) == Data("FSS1".utf8) else { throw AuthError() }
        let kid = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let version = data.subdata(in: 8..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        guard let sk = ring[kid] else { throw AuthError() }
        let aad = Data("FSS1".utf8) + data.subdata(in: 4..<16) + Data(spaceID.utf8)
        let z: Data
        do { z = try XChaCha.open(data.subdata(in: (16 + nonceSize)..<data.count), key: sk,
                                  nonce: data.subdata(in: 16..<(16 + nonceSize)), aad: aad) } catch { throw AuthError() }
        return (version, try gunzip(z))
    }

    /// Minimal gzip reader (header + raw DEFLATE + trailer).
    static func gunzip(_ d: Data) throws -> Data {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw AuthError() }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { p += 2 + Int(b[p]) | Int(b[p + 1]) << 8 }
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < b.count - 8 else { throw AuthError() }
        let deflated = Data(b[p..<(b.count - 8)])
        return try (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
