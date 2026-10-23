import Foundation

/// What the UI talks to: the NAS directly on the LAN, or through the relay
/// (end-to-end encrypted, with the NAS collecting work on its own schedule).
protocol Backend: AnyObject, Sendable {
    var isRemote: Bool { get }
    var modeLabel: String { get }
    var canPurge: Bool { get async }
    func close()

    func me() async throws -> (User, Device?)
    func info() async throws -> ServerInfo
    func logout() async
    func changePassword(old: String, new: String, signOutOthers: Bool) async throws
    func devices() async throws -> ([Device], String)
    func renameDevice(_ id: String, name: String) async throws
    func revokeDevice(_ id: String) async throws
    func audit() async throws -> [AuditEntry]
    func stats() async throws -> Stats

    func categories() async throws -> [FSCategory]
    func createCategory(name: String, color: String, icon: String) async throws
    func updateCategory(_ id: String, name: String?, color: String?, icon: String?) async throws
    func deleteCategory(_ id: String) async throws

    func list(_ parentID: String?, dirsOnly: Bool) async throws -> Listing
    func node(_ id: String) async throws -> (Node, [Crumb])
    func createFolder(parentID: String?, name: String) async throws
    func rename(_ id: String, to name: String) async throws
    func batch(_ action: String, ids: [String], parentID: String?, categoryID: String?) async throws
    func walk(_ id: String) async throws -> [WalkEntry]
    func timeline(before: Date?, category: String?) async throws -> [Node]
    func tagged(_ categoryID: String) async throws -> [Node]
    func search(_ q: String) async throws -> [Node]
    func trashList() async throws -> [Node]
    func restore(_ id: String) async throws
    func purge(_ id: String) async throws
    func emptyTrash() async throws

    /// Downloads one file to `to`, resuming a previous partial download.
    func download(_ n: Node, to: URL, progress: @escaping @Sendable (Int64) -> Void,
                  phase: @escaping @Sendable (String?) -> Void) async throws
    /// Live changes; finishes or throws when the connection drops.
    func events() -> AsyncThrowingStream<ServerEvent, Error>
    /// One-time code that adds a device through the relay.
    func createPairingCode() async throws -> (String, Date)
}

extension Node {
    fileprivate static func from(_ any: Any) -> Node? {
        guard let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(Node.self, from: d)
    }
}

func decodeList<T: Decodable>(_ any: Any?) -> [T] {
    guard let any, let d = try? JSONSerialization.data(withJSONObject: any) else { return [] }
    return (try? JSONDecoder().decode([T].self, from: d)) ?? []
}

func decodeOne<T: Decodable>(_ any: Any?) -> T? {
    guard let any, let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

/// Direct HTTPS to the NAS on the LAN.
final class DirectBackend: Backend, @unchecked Sendable {
    let http: HTTP
    init(http: HTTP) { self.http = http }

    var isRemote: Bool { false }
    var modeLabel: String { "局域网直连" }
    var canPurge: Bool { true }
    func close() { http.invalidate() }

    static let directLimit: Int64 = 4 << 20

    /// Reads /info without credentials and captures the certificate fingerprint.
    static func probe(_ input: String) async throws -> (URL, ServerInfo, String?) {
        var s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw FSError(status: 0, code: "input", message: "请输入服务器地址") }
        let hadScheme = s.contains("://")
        if !hadScheme { s = "https://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false, ["https", "http"].contains(c.scheme ?? "") else {
            throw FSError(status: 0, code: "input", message: "服务器地址格式不正确")
        }
        if !hadScheme && c.port == nil { c.port = 8443 }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        let base = c.url!
        let h = HTTP(base: base, fingerprint: nil, acceptAny: true)
        defer { h.invalidate() }
        var r = h.request("GET", "/api/v1/info")
        r.timeoutInterval = 10
        let (status, data) = try await h.raw(r)
        guard status == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["api"] != nil else {
            throw FSError(status: status, code: "not_fileswitch", message: "该地址不是 FileSwitch 服务器")
        }
        // A certificate the OS trusts needs no pin.
        let trusted = await Self.systemTrusts(base)
        return (base, Self.info(j), trusted ? nil : h.seenFingerprint)
    }

    private static func systemTrusts(_ base: URL) async -> Bool {
        guard base.scheme == "https" else { return true }
        let h = HTTP(base: base, fingerprint: nil)
        defer { h.invalidate() }
        return (try? await h.raw(h.request("GET", "/api/v1/info"))) != nil
    }

    static func info(_ j: [String: Any]) -> ServerInfo {
        ServerInfo(name: j["name"] as? String ?? "FileSwitch", version: j["version"] as? String ?? "",
                   encryptedAtRest: j["encrypted_at_rest"] as? Bool ?? false,
                   relayURL: (j["relay"] as? [String: Any])?["url"] as? String ?? "")
    }

    func login(username: String, password: String, deviceName: String, platform: String) async throws -> String {
        let j = try await http.json(http.request("POST", "/api/v1/auth/login", json: [
            "username": username, "password": password, "device_name": deviceName, "platform": platform,
        ]))
        guard let t = j["token"] as? String else { throw FSError(status: 0, code: "login", message: "登录失败") }
        return t
    }

    func enrollRelay() async throws -> [String: Any] { try await http.json(http.request("POST", "/api/v1/relay/enroll")) }

    func me() async throws -> (User, Device?) {
        let j = try await http.json(http.request("GET", "/api/v1/auth/me"))
        guard let u: User = decodeOne(j["user"]) else { throw FSError(status: 0, code: "decode", message: "无法解析账户信息") }
        return (u, decodeOne(j["device"]))
    }

    func info() async throws -> ServerInfo { Self.info(try await http.json(http.request("GET", "/api/v1/info"))) }

    func logout() async { _ = try? await http.json(http.request("POST", "/api/v1/auth/logout")) }

    func changePassword(old: String, new: String, signOutOthers: Bool) async throws {
        try await http.json(http.request("POST", "/api/v1/auth/password",
                                         json: ["old_password": old, "new_password": new, "sign_out_others": signOutOthers]))
    }

    func devices() async throws -> ([Device], String) {
        let j = try await http.json(http.request("GET", "/api/v1/devices"))
        return (decodeList(j["devices"]), j["current"] as? String ?? "")
    }

    func renameDevice(_ id: String, name: String) async throws {
        try await http.json(http.request("PATCH", "/api/v1/devices/\(id)", json: ["name": name]))
    }

    func revokeDevice(_ id: String) async throws { try await http.json(http.request("DELETE", "/api/v1/devices/\(id)")) }

    func audit() async throws -> [AuditEntry] { decodeList(try await http.json(http.request("GET", "/api/v1/audit"))["entries"]) }

    func stats() async throws -> Stats {
        let j = try await http.json(http.request("GET", "/api/v1/stats"))
        let s = j["stats"] as? [String: Any] ?? [:]
        func n(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        return Stats(files: n(s["files"]), folders: n(s["folders"]), bytes: n(s["bytes"]), trashBytes: n(s["trash_bytes"]),
                     diskFree: n(j["disk_free"]), diskTotal: n(j["disk_total"]))
    }

    func categories() async throws -> [FSCategory] {
        decodeList(try await http.json(http.request("GET", "/api/v1/categories"))["categories"])
    }

    func createCategory(name: String, color: String, icon: String) async throws {
        try await http.json(http.request("POST", "/api/v1/categories", json: ["name": name, "color": color, "icon": icon]))
    }

    func updateCategory(_ id: String, name: String?, color: String?, icon: String?) async throws {
        var b: [String: Any] = [:]
        if let name { b["name"] = name }
        if let color { b["color"] = color }
        if let icon { b["icon"] = icon }
        try await http.json(http.request("PATCH", "/api/v1/categories/\(id)", json: b))
    }

    func deleteCategory(_ id: String) async throws { try await http.json(http.request("DELETE", "/api/v1/categories/\(id)")) }

    func list(_ parentID: String?, dirsOnly: Bool) async throws -> Listing {
        var q: [String: String] = [:]
        if let parentID, !parentID.isEmpty { q["parent"] = parentID }
        if dirsOnly { q["dirs"] = "1" }
        let j = try await http.json(http.request("GET", "/api/v1/nodes", query: q))
        guard let parent: Node = decodeOne(j["parent"]) else { throw FSError(status: 404, code: "not_found", message: "文件夹不存在") }
        return Listing(parent: parent, path: decodeList(j["path"]), children: decodeList(j["children"]))
    }

    func node(_ id: String) async throws -> (Node, [Crumb]) {
        let j = try await http.json(http.request("GET", "/api/v1/nodes/\(id)"))
        guard let n: Node = decodeOne(j["node"]) else { throw FSError(status: 404, code: "not_found", message: "文件不存在") }
        return (n, decodeList(j["path"]))
    }

    func createFolder(parentID: String?, name: String) async throws {
        var b: [String: Any] = ["name": name, "conflict": "rename"]
        if let parentID { b["parent_id"] = parentID }
        try await http.json(http.request("POST", "/api/v1/nodes/folder", json: b))
    }

    /// Creates a folder and returns its id (uploads need it).
    func mkdir(parentID: String?, categoryID: String?, name: String? = nil, path: String? = nil,
               timeline: Bool = false, mtime: Date? = nil) async throws -> String {
        var b: [String: Any] = ["conflict": "rename", "timeline": timeline]
        if let parentID { b["parent_id"] = parentID }
        if let categoryID { b["category_id"] = categoryID }
        if let name { b["name"] = name }
        if let path { b["path"] = path }
        if let mtime { b["mtime"] = Int64(mtime.timeIntervalSince1970 * 1000) }
        let j = try await http.json(http.request("POST", "/api/v1/nodes/folder", json: b))
        return j["id"] as? String ?? ""
    }

    func rename(_ id: String, to name: String) async throws {
        try await http.json(http.request("PATCH", "/api/v1/nodes/\(id)", json: ["name": name]))
    }

    func batch(_ action: String, ids: [String], parentID: String?, categoryID: String?) async throws {
        var b: [String: Any] = ["action": action, "ids": ids]
        if let parentID { b["parent_id"] = parentID }
        if let categoryID { b["category_id"] = categoryID }
        let j = try await http.json(http.request("POST", "/api/v1/nodes/batch", json: b))
        let failed = (j["results"] as? [[String: Any]] ?? []).filter { $0["ok"] as? Bool != true }
        if let f = failed.first { throw FSError(status: 400, code: "batch", message: f["error"] as? String ?? "操作失败") }
    }

    func walk(_ id: String) async throws -> [WalkEntry] {
        let j = try await http.json(http.request("GET", "/api/v1/nodes/\(id)/walk"))
        return (j["entries"] as? [[String: Any]] ?? []).compactMap { e in
            guard let n: Node = decodeOne(e), let rel = e["rel_path"] as? String else { return nil }
            return WalkEntry(node: n, relPath: rel)
        }
    }

    func timeline(before: Date?, category: String?) async throws -> [Node] {
        var q = ["limit": "300"]
        if let before { q["before"] = String(Int64(before.timeIntervalSince1970 * 1000)) }
        if let category, !category.isEmpty { q["category"] = category }
        return decodeList(try await http.json(http.request("GET", "/api/v1/timeline", query: q))["items"])
    }

    func tagged(_ categoryID: String) async throws -> [Node] {
        decodeList(try await http.json(http.request("GET", "/api/v1/tagged/\(categoryID)", query: ["limit": "500"]))["items"])
    }

    func search(_ q: String) async throws -> [Node] {
        decodeList(try await http.json(http.request("GET", "/api/v1/search", query: ["q": q]))["items"])
    }

    func trashList() async throws -> [Node] { decodeList(try await http.json(http.request("GET", "/api/v1/trash"))["items"]) }
    func restore(_ id: String) async throws { try await http.json(http.request("POST", "/api/v1/trash/\(id)/restore")) }
    func purge(_ id: String) async throws { try await http.json(http.request("DELETE", "/api/v1/trash/\(id)")) }
    func emptyTrash() async throws { try await http.json(http.request("DELETE", "/api/v1/trash")) }

    func createPairingCode() async throws -> (String, Date) {
        let j = try await http.json(http.request("POST", "/api/v1/relay/pair"))
        let exp = (j["expires"] as? NSNumber)?.doubleValue ?? 0
        return (j["code"] as? String ?? "", Date(timeIntervalSince1970: exp / 1000))
    }

    // --- transfers ---

    /// Uploads one file as relPath below the destination; large files resume after errors.
    func upload(file: URL, size: Int64, parentID: String?, categoryID: String?, relPath: String, timeline: Bool,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let mtime = Int64(((try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date())
            .timeIntervalSince1970 * 1000)
        if size <= Self.directLimit {
            var q = ["path": relPath, "size": String(size), "mtime": String(mtime), "conflict": "rename"]
            if timeline { q["timeline"] = "1" }
            if let parentID { q["parent_id"] = parentID }
            if let categoryID { q["category_id"] = categoryID }
            let data = try Data(contentsOf: file)
            let (status, body) = try await http.upload(http.request("PUT", "/api/v1/files", query: q), data: data, progress: progress)
            if status >= 400 { throw HTTP.error(status: status, data: body) }
            return
        }
        var b: [String: Any] = ["path": relPath, "size": size, "mtime": mtime, "timeline": timeline, "conflict": "rename"]
        if let parentID { b["parent_id"] = parentID }
        if let categoryID { b["category_id"] = categoryID }
        let created = try await http.json(http.request("POST", "/api/v1/uploads", json: b))
        guard let up = created["upload"] as? [String: Any], let id = up["id"] as? String else { throw FSError(status: 0, code: "upload", message: "无法创建上传") }
        let chunk = Int64((created["chunk_size"] as? NSNumber)?.intValue ?? (8 << 20))
        var received = (up["received"] as? NSNumber)?.int64Value ?? 0
        var failures = 0
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        while received < size {
            try Task.checkCancellation()
            do {
                try fh.seek(toOffset: UInt64(received))
                let data = try fh.read(upToCount: Int(min(chunk, size - received))) ?? Data()
                let base = received
                let (status, body) = try await http.upload(http.request("PUT", "/api/v1/uploads/\(id)", query: ["offset": String(received)]),
                                                           data: data, progress: { progress(base + $0) })
                let j = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                if status == 409, let r = j["received"] as? NSNumber { received = r.int64Value; continue }
                if status >= 400 { throw HTTP.error(status: status, data: body) }
                received = (j["received"] as? NSNumber)?.int64Value ?? received
                failures = 0
            } catch let e as FSError where e.isNetwork && e.code != "canceled" {
                failures += 1
                if failures > 10 { throw e }
                try await Task.sleep(for: .seconds(min(30, 1 << failures)))
                if let st = try? await http.json(http.request("GET", "/api/v1/uploads/\(id)")),
                   let r = (st["upload"] as? [String: Any])?["received"] as? NSNumber { received = r.int64Value }
            }
        }
        try await http.json(http.request("POST", "/api/v1/uploads/\(id)/complete"))
    }

    func download(_ n: Node, to: URL, progress: @escaping @Sendable (Int64) -> Void,
                  phase: @escaping @Sendable (String?) -> Void) async throws {
        let part = to.appendingPathExtension("fsdownload")
        var failures = 0
        while true {
            try Task.checkCancellation()
            var have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
            if have > n.size { try? FileManager.default.removeItem(at: part); have = 0 }
            if have == n.size && n.size > 0 { break }
            var headers: [String: String] = [:]
            if have > 0 { headers["Range"] = "bytes=\(have)-"; if !n.sha256.isEmpty { headers["If-Range"] = "\"\(n.sha256)\"" } }
            do {
                let base = have
                let status = try await http.download(http.request("GET", "/api/v1/nodes/\(n.id)/content", headers: headers),
                                                     to: part, append: have > 0, progress: { progress(base + $0) })
                if status == 416 { try? FileManager.default.removeItem(at: part); continue }
                if status >= 400 { throw FSError(status: status, code: "download", message: "下载失败 (\(status))") }
                break
            } catch let e as FSError where e.isNetwork && e.code != "canceled" {
                failures += 1
                if failures > 8 { throw e }
                try await Task.sleep(for: .seconds(min(30, 1 << failures)))
            } catch {
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                failures += 1
                if failures > 8 { throw http.wrap(error) }
                try await Task.sleep(for: .seconds(min(30, 1 << failures)))
            }
        }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: part, to: to)
        try? FileManager.default.setAttributes([.modificationDate: n.mtime], ofItemAtPath: to.path)
    }

    func events() -> AsyncThrowingStream<ServerEvent, Error> {
        let src = http.events(http.request("GET", "/api/v1/events"))
        return AsyncThrowingStream { cont in
            let t = Task {
                do {
                    cont.yield(.hello)
                    for try await j in src {
                        guard let type = j["type"] as? String else { continue }
                        var ev = ServerEvent(type: type)
                        if let n = j["node"] { ev.node = decodeOne(n) }
                        ev.parentID = j["parent_id"] as? String ?? ""
                        ev.oldParentID = j["old_parent_id"] as? String ?? ""
                        ev.deviceID = j["device_id"] as? String ?? ""
                        ev.target = j["target"] as? String ?? ""
                        cont.yield(ev)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
