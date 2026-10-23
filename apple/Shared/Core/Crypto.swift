import CryptoKit
import Foundation

/// XChaCha20-Poly1305 built from CryptoKit's (hardware-accelerated)
/// ChaCha20-Poly1305: HChaCha20 derives a subkey from the key and the first
/// 16 nonce bytes; the last 8 nonce bytes become the IETF nonce.
enum XChaCha {
    struct AuthError: Error {}

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    private static func words(_ b: some Collection<UInt8>) -> [UInt32] {
        let a = Array(b)
        return stride(from: 0, to: a.count, by: 4).map {
            UInt32(a[$0]) | UInt32(a[$0 + 1]) << 8 | UInt32(a[$0 + 2]) << 16 | UInt32(a[$0 + 3]) << 24
        }
    }

    static func hchacha20(key: [UInt8], nonce16: ArraySlice<UInt8>) -> [UInt8] {
        var s: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574] + words(key) + words(nonce16)
        for _ in 0..<10 {
            quarter(&s, 0, 4, 8, 12); quarter(&s, 1, 5, 9, 13); quarter(&s, 2, 6, 10, 14); quarter(&s, 3, 7, 11, 15)
            quarter(&s, 0, 5, 10, 15); quarter(&s, 1, 6, 11, 12); quarter(&s, 2, 7, 8, 13); quarter(&s, 3, 4, 9, 14)
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for w in [s[0], s[1], s[2], s[3], s[12], s[13], s[14], s[15]] {
            out += [UInt8(w & 0xff), UInt8(w >> 8 & 0xff), UInt8(w >> 16 & 0xff), UInt8(w >> 24)]
        }
        return out
    }

    private static func parts(key: Data, nonce: Data) throws -> (SymmetricKey, ChaChaPoly.Nonce) {
        guard key.count == 32, nonce.count == 24 else { throw AuthError() }
        let n = [UInt8](nonce)
        let sub = hchacha20(key: [UInt8](key), nonce16: n[0..<16])
        return (SymmetricKey(data: sub), try ChaChaPoly.Nonce(data: [0, 0, 0, 0] + n[16..<24]))
    }

    /// Returns ciphertext ‖ tag (same layout as Go's Seal).
    static func seal(_ plain: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        let (k, n) = try parts(key: key, nonce: nonce)
        let box = try ChaChaPoly.seal(plain, using: k, nonce: n, authenticating: aad)
        // CryptoKit returns slices of a shared buffer; copy into a zero-based Data
        var out = Data(capacity: plain.count + 16)
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    static func open(_ sealed: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16 else { throw AuthError() }
        let (k, n) = try parts(key: key, nonce: nonce)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: n, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return Data(Array(try ChaChaPoly.open(box, using: k, authenticating: aad)))
        } catch {
            throw AuthError()
        }
    }
}

extension Data {
    static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        self = out
    }
}

enum Base32 {
    static func decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = Data(), buf = 0, bits = 0
        for ch in s.uppercased() where !" =-".contains(ch) {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buf = (buf << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buf >> bits) & 0xff))
            }
        }
        return out
    }
}

func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Certificate fingerprint as AA:BB:… (matches the server log).
func certFingerprint(_ der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
}

func normalizedFingerprint(_ s: String) -> String { s.replacingOccurrences(of: ":", with: "").uppercased() }
