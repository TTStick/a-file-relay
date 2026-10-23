import Foundation
import Security

/// Device tokens and relay keys live in the Keychain; profiles (non-secret) in a JSON file.
enum Keychain {
    private static let service = "com.fileswitch.app"

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ data: Data?, _ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func token(_ profile: String) -> String? { get("token_\(profile)").flatMap { String(data: $0, encoding: .utf8) } }
    static func setToken(_ profile: String, _ token: String?) { set(token.map { Data($0.utf8) }, "token_\(profile)") }
    static func relay(_ profile: String) -> RelayCreds? { get("relay_\(profile)").flatMap(RelayCreds.init(data:)) }
    static func setRelay(_ profile: String, _ c: RelayCreds?) { set(c?.data, "relay_\(profile)") }
}

enum ProfileStore {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileSwitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    struct Saved: Codable {
        var profiles: [ServerProfile] = []
        var activeID: String?
    }

    static func load() -> Saved {
        guard let d = try? Data(contentsOf: file) else { return Saved() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode(Saved.self, from: d)) ?? Saved()
    }

    static func save(_ s: Saved) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(s) { try? d.write(to: file, options: .atomic) }
    }
}

var platformName: String {
    #if os(macOS)
    "macos"
    #else
    "ios"
    #endif
}

var defaultDeviceName: String {
    #if os(macOS)
    var h = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    if h.hasSuffix(".local") { h.removeLast(6) }
    return h.isEmpty ? "Mac" : h
    #else
    return "iPhone"
    #endif
}
