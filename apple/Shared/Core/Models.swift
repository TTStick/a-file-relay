import Foundation
import SwiftUI

private func ms(_ v: Int64?) -> Date { Date(timeIntervalSince1970: Double(v ?? 0) / 1000) }

struct Node: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var parentID: String
    var name: String
    var isDir: Bool
    var size: Int64
    var mime: String
    var sha256: String
    var categoryID: String
    var timeline: Bool
    var deviceID: String
    var deviceName: String
    var mtime: Date
    var createdAt: Date
    var updatedAt: Date
    var childCount: Int
    var trashedAt: Date?
    var location: String

    enum K: String, CodingKey {
        case id, name, size, mime, sha256, timeline, mtime, location
        case parentID = "parent_id", isDir = "is_dir", categoryID = "category_id", deviceID = "device_id"
        case deviceName = "device_name", createdAt = "created_at", updatedAt = "updated_at"
        case childCount = "child_count", trashedAt = "trashed_at"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        categoryID = try c.decodeIfPresent(String.self, forKey: .categoryID) ?? ""
        timeline = try c.decodeIfPresent(Bool.self, forKey: .timeline) ?? false
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        mtime = ms(try c.decodeIfPresent(Int64.self, forKey: .mtime))
        createdAt = ms(try c.decodeIfPresent(Int64.self, forKey: .createdAt))
        updatedAt = ms(try c.decodeIfPresent(Int64.self, forKey: .updatedAt))
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
        let t = try c.decodeIfPresent(Int64.self, forKey: .trashedAt)
        trashedAt = (t ?? 0) > 0 ? ms(t) : nil
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
    }

    var ext: String {
        guard !isDir, let i = name.lastIndex(of: "."), i != name.startIndex else { return "" }
        return name[name.index(after: i)...].lowercased()
    }

    var isImage: Bool { ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) }
}

struct Crumb: Hashable, Decodable, Sendable {
    var id: String
    var name: String
}

struct Listing: Sendable {
    var parent: Node
    var path: [Crumb]
    var children: [Node]
}

struct WalkEntry: Sendable {
    var node: Node
    var relPath: String
}

struct FSCategory: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var name: String
    var colorHex: String
    var icon: String
    var sort: Int
    var folderID: String
    var count: Int

    enum K: String, CodingKey { case id, name, color, icon, sort, count, folderID = "folder_id" }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .color) ?? "#4F7CFF"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }

    init(id: String, name: String, colorHex: String, icon: String) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.icon = icon
        sort = 0; folderID = ""; count = 0
    }

    var color: Color { Color(hex: colorHex) }
}

struct User: Hashable, Decodable, Sendable {
    var id: String
    var username: String
    var isAdmin: Bool
    var rootID: String

    enum K: String, CodingKey { case id, username, isAdmin = "is_admin", rootID = "root_id" }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        rootID = try c.decodeIfPresent(String.self, forKey: .rootID) ?? ""
    }
}

struct Device: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var name: String
    var platform: String
    var lastSeen: Date
    var lastIP: String
    var relay: Bool
    var remote: Bool

    enum K: String, CodingKey { case id, name, platform, relay, remote, lastSeen = "last_seen_at", lastIP = "last_ip" }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        lastSeen = ms(try c.decodeIfPresent(Int64.self, forKey: .lastSeen))
        lastIP = try c.decodeIfPresent(String.self, forKey: .lastIP) ?? ""
        relay = try c.decodeIfPresent(Bool.self, forKey: .relay) ?? false
        remote = try c.decodeIfPresent(Bool.self, forKey: .remote) ?? false
    }
}

struct ServerInfo: Sendable {
    var name: String
    var version: String
    var encryptedAtRest: Bool
    var relayURL: String
}

struct Stats: Sendable {
    var files: Int64 = 0
    var folders: Int64 = 0
    var bytes: Int64 = 0
    var trashBytes: Int64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
}

struct AuditEntry: Identifiable, Decodable, Sendable {
    var id: Int64
    var action: String
    var detail: String
    var ip: String
    var at: Date

    enum K: String, CodingKey { case id, action, detail, ip, at }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(Int64.self, forKey: .id)
        action = try c.decode(String.self, forKey: .action)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        at = ms(try c.decodeIfPresent(Int64.self, forKey: .at))
    }
}

/// A NAS this device knows. Secrets (tokens, relay keys) live in the Keychain.
struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// Direct (LAN) address; empty for devices added with a pairing code.
    var url: String
    var relayURL: String = ""
    var username: String = ""
    var fingerprint: String?
    var deviceName: String = ""
    var lastUsed: Date?
}

struct ServerEvent: Sendable {
    var type: String
    var node: Node?
    var parentID: String = ""
    var oldParentID: String = ""
    var deviceID: String = ""
    var target: String = ""

    static let hello = ServerEvent(type: "hello")
}

struct FSError: LocalizedError, Sendable {
    var status: Int
    var code: String
    var message: String
    var errorDescription: String? { message }
    var isNetwork: Bool { status == 0 }
    var unauthorized: Bool { status == 401 }

    static func lanOnly() -> FSError { FSError(status: 0, code: "lan_only", message: "该功能只能在局域网直连 NAS 时使用") }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0x4F7CFF
        if hex.hasPrefix("#"), hex.count == 7 { Scanner(string: String(hex.dropFirst())).scanHexInt64(&v) }
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
