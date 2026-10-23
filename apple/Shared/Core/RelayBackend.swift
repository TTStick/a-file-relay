import Foundation

/// Relay credentials of this device (stored in the Keychain), in the shape of
/// the NAS's enrollment bundle.
struct RelayCreds: @unchecked Sendable {
    var json: [String: Any]

    var url: String { ((json["relay"] as? [String: Any])?["url"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var fingerprint: String? { (json["relay"] as? [String: Any])?["fingerprint"] as? String }
    var spaceID: String { json["space_id"] as? String ?? "" }
    var deviceID: String { json["device_id"] as? String ?? "" }
    var deviceKey: Data { Data(base64Encoded: json["device_key"] as? String ?? "") ?? Data() }
    var token: String { json["relay_token"] as? String ?? "" }
    var serverName: String { json["server_name"] as? String ?? "FileSwitch" }
    var username: String { (json["user"] as? [String: Any])?["username"] as? String ?? "" }
    var keyring: (E2E.Keyring, UInt32) { E2E.keyring(from: json["keyring"] as? [String: Any] ?? [:]) }

    var data: Data { (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
    init(json: [String: Any]) { self.json = json }
    init?(data: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        json = j
    }
}

/// Decrypted metadata the NAS publishes, with indexes for browsing.
struct Snapshot: Sendable {
    struct Server: Decodable { var name: String?; var version: String?; var encrypted_at_rest: Bool? }
    struct Policy: Decodable { var remote_purge: Bool?; var remote_pairing: Bool? }
    struct SStats: Decodable { var files: Int64?; var folders: Int64?; var bytes: Int64?; var trash_bytes: Int64? }
    struct Raw: Decodable {
        var kid: UInt32
        var server: Server?
        var policy: Policy?
        var user: User
        var nodes: [Node]?
        var trash: [Node]?
        var categories: [FSCategory]?
        var devices: [Device]?
        var stats: SStats?
    }

    var version: UInt64
    var kid: UInt32
    var serverName: String
    var serverVersion: String
    var encrypted: Bool
    var remotePurge: Bool
    var remotePairing: Bool
    var user: User
    var nodes: [Node]
    var trash: [Node]
    var categories: [FSCategory]
    var devices: [Device]
    var stats: Stats
    private(set) var byID: [String: Node] = [:]
    private(set) var kids: [String: [Node]] = [:]

    init(version: UInt64, raw r: Raw) {
        self.version = version
        kid = r.kid
        serverName = r.server?.name ?? "FileSwitch"
        serverVersion = r.server?.version ?? ""
        encrypted = r.server?.encrypted_at_rest ?? true
        remotePurge = r.policy?.remote_purge ?? false
        remotePairing = r.policy?.remote_pairing ?? false
        user = r.user
        nodes = r.nodes ?? []
        trash = r.trash ?? []
        categories = r.categories ?? []
        devices = r.devices ?? []
        stats = Stats(files: r.stats?.files ?? 0, folders: r.stats?.folders ?? 0, bytes: r.stats?.bytes ?? 0,
                      trashBytes: r.stats?.trash_bytes ?? 0)
        reindex()
    }

    mutating func reindex() {
        byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        kids = Dictionary(grouping: nodes.filter { !$0.parentID.isEmpty }, by: \.parentID)
    }

    func path(_ id: String) -> [Crumb] {
        var out: [Crumb] = []
        var cur = byID[id]
        var guardCount = 0
        while let c = cur, guardCount < 128 {
            out.insert(Crumb(id: c.id, name: c.name), at: 0)
            cur = c.parentID.isEmpty ? nil : byID[c.parentID]
            guardCount += 1
        }
        return out
    }

    func located(_ n: Node) -> Node {
        var x = n
        if !n.parentID.isEmpty { x.location = "/" + path(n.parentID).dropFirst().map(\.name).joined(separator: "/") }
        return x
    }

    mutating func update(_ id: String, _ f: (inout Node) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        f(&nodes[i])
        reindex()
    }

    mutating func removeSubtree(_ id: String) -> Node? {
        guard let n = byID[id] else { return nil }
        var gone: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for x in nodes where !gone.contains(x.id) && gone.contains(x.parentID) {
                gone.insert(x.id)
                grew = true
            }
        }
        nodes.removeAll { gone.contains($0.id) }
        reindex()
        return n
    }
}

/// Talks to the NAS through the relay. Reads come from the encrypted snapshot;
/// changes are sealed operations the NAS applies on its next sync, shown
/// optimistically until it confirms.
actor RelayBackend: Backend {
    nonisolated let http: HTTP
    private(set) var creds: RelayCreds
    nonisolated let onCredsChanged: @Sendable (RelayCreds) -> Void
    nonisolated let onLocal: @Sendable (ServerEvent) -> Void

    private var snap: Snapshot?
    private var replySeq: Int64 = -1
    private var handlers: [String: (Result<[String: Any], FSError>) -> Void] = [:]
    private var optimistic: [String: (inout Snapshot) -> Void] = [:]
    private var requested: [String: Date] = [:]
    private var cacheWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var replyPoller: Task<Void, Never>?
    private var lastStatus = Date.distantPast
    private(set) var nasSeen: Date?

    var pendingOps: Int { handlers.count }

    init(creds: RelayCreds, onCredsChanged: @escaping @Sendable (RelayCreds) -> Void,
         onLocal: @escaping @Sendable (ServerEvent) -> Void) {
        self.creds = creds
        self.onCredsChanged = onCredsChanged
        self.onLocal = onLocal
        http = HTTP(base: URL(string: creds.url)!, fingerprint: creds.fingerprint, bearer: creds.token)
    }

    nonisolated var isRemote: Bool { true }
    nonisolated var modeLabel: String { "经中转站" }
    var canPurge: Bool { snap?.remotePurge ?? false }
    var canPair: Bool { snap?.remotePairing ?? false }
    nonisolated func close() { http.invalidate() }

    // MARK: keys & snapshot

    private func refreshKeyring() async throws {
        let j = try await http.json(http.request("GET", "/r/v1/keyring"))
        let env = E2E.Envelope(n: j["n"] as? String ?? "", c: j["c"] as? String ?? "")
        let p = try E2E.openEnvelope(creds.deviceKey, env, aad: E2E.keyringAAD(creds.deviceID))
        creds.json["keyring"] = try JSONSerialization.jsonObject(with: p)
        onCredsChanged(creds)
    }

    private func ensure() async throws -> Snapshot {
        if let snap { return snap }
        _ = try await fetchSnapshot()
        guard let snap else { throw FSError(status: 0, code: "no_snapshot", message: "NAS 还没有把数据同步到中转站，请确认 NAS 在线") }
        return snap
    }

    /// Fetches the snapshot if it changed; returns new timeline items from other devices.
    @discardableResult
    private func fetchSnapshot() async throws -> [Node] {
        var q: [String: String] = [:]
        if let v = snap?.version { q["have"] = String(v) }
        let (status, data) = try await http.raw(http.request("GET", "/r/v1/snapshot", query: q))
        switch status {
        case 304: return []
        case 404: throw FSError(status: 0, code: "no_snapshot", message: "NAS 还没有把数据同步到中转站，请确认 NAS 在线")
        case 401: throw FSError(status: 401, code: "unauthorized", message: "此设备的中转授权已失效")
        case 200: break
        default: throw HTTP.error(status: status, data: data)
        }
        var opened: (UInt64, Data)
        do { opened = try E2E.openSnapshot(data, spaceID: creds.spaceID, ring: creds.keyring.0) } catch {
            try await refreshKeyring() // the space key may have rotated
            opened = try E2E.openSnapshot(data, spaceID: creds.spaceID, ring: creds.keyring.0)
        }
        let raw = try JSONDecoder().decode(Snapshot.Raw.self, from: opened.1)
        var fresh = Snapshot(version: opened.0, raw: raw)
        for f in optimistic.values { f(&fresh) }
        let before = snap
        snap = fresh
        guard let before else { return [] }
        return fresh.nodes.filter { $0.timeline && before.byID[$0.id] == nil && $0.deviceID != creds.deviceID }
    }

    private func refreshStatus() async {
        lastStatus = Date()
        guard let j = try? await http.json(http.request("GET", "/r/v1/status")) else { return }
        let seen = (j["nas_seen"] as? NSNumber)?.doubleValue ?? 0
        let now = (j["now"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        nasSeen = seen == 0 ? nil : Date().addingTimeInterval(-(now - seen) / 1000)
        onLocal(ServerEvent(type: "relay.status"))
    }

    func status() -> (pending: Int, nasSeen: Date?) { (handlers.count, nasSeen) }

    // MARK: operations

    @discardableResult
    private func op(_ body: [String: Any], wait: Bool = false, timeout: Duration = .seconds(300),
                    optimistic f: ((inout Snapshot) -> Void)? = nil) async throws -> [String: Any] {
        let id = Data.random(16).hex
        var b = body
        b["ts"] = Int64(Date().timeIntervalSince1970 * 1000)
        let env = try E2E.sealEnvelope(creds.deviceKey, try JSONSerialization.data(withJSONObject: b), aad: E2E.opAAD(creds.deviceID, id))
        try await http.json(http.request("POST", "/r/v1/ops", json: ["id": id, "n": env.n, "c": env.c]))
        if let f {
            optimistic[id] = f
            if snap != nil { f(&snap!) }
            onLocal(.hello)
        }
        startReplyPoller()
        if !wait {
            handlers[id] = { [weak self] r in
                guard case .failure(let e) = r, let self else { return }
                Task { await self.dropView(); self.onLocal(ServerEvent(type: "op.failed", target: e.message)) }
            }
            onLocal(ServerEvent(type: "relay.status"))
            return [:]
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            var done = false
            handlers[id] = { r in
                guard !done else { return }
                done = true
                c.resume(with: r.mapError { $0 as Error })
            }
            onLocal(ServerEvent(type: "relay.status"))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: String) {
        handlers.removeValue(forKey: id)?(.failure(FSError(status: 0, code: "nas_offline", message: "NAS 暂未处理（可能离线），操作会在 NAS 上线后执行")))
        onLocal(ServerEvent(type: "relay.status"))
    }

    private func dropView() {
        snap = nil
        onLocal(.hello)
    }

    private func startReplyPoller() {
        guard replyPoller == nil else { return }
        replyPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if await self.handlers.isEmpty { await self.stopPoller(); return }
                try? await self.pullReplies()
            }
        }
    }

    private func stopPoller() { replyPoller = nil }

    private func pullReplies() async throws {
        if replySeq < 0 && handlers.isEmpty {
            // first contact: skip replies from earlier sessions
            let j = try await http.json(http.request("GET", "/r/v1/replies", query: ["after": "0"]))
            replySeq = ((j["replies"] as? [[String: Any]])?.last?["seq"] as? NSNumber)?.int64Value ?? 0
            return
        }
        let j = try await http.json(http.request("GET", "/r/v1/replies", query: ["after": String(max(replySeq, 0))]))
        for r in j["replies"] as? [[String: Any]] ?? [] {
            replySeq = max(replySeq, (r["seq"] as? NSNumber)?.int64Value ?? 0)
            guard let id = r["op"] as? String, let h = handlers.removeValue(forKey: id) else { continue }
            optimistic.removeValue(forKey: id)
            let body = r["body"] as? [String: Any] ?? [:]
            do {
                let p = try E2E.openEnvelope(creds.deviceKey, .init(n: body["n"] as? String ?? "", c: body["c"] as? String ?? ""),
                                             aad: E2E.replyAAD(creds.deviceID, id))
                let reply = try JSONSerialization.jsonObject(with: p) as? [String: Any] ?? [:]
                if reply["ok"] as? Bool == true {
                    h(.success(reply["data"] as? [String: Any] ?? [:]))
                } else {
                    h(.failure(FSError(status: 400, code: "nas", message: reply["error"] as? String ?? "NAS 拒绝了该操作")))
                }
            } catch {
                h(.failure(FSError(status: 0, code: "auth", message: "收到无法验证的回复，已忽略")))
            }
        }
        onLocal(ServerEvent(type: "relay.status"))
    }

    // MARK: events

    nonisolated func events() -> AsyncThrowingStream<ServerEvent, Error> {
        let src = http.events(http.request("GET", "/r/v1/events"))
        return AsyncThrowingStream { cont in
            let t = Task {
                do {
                    for try await j in src {
                        switch j["type"] as? String {
                        case "hello":
                            await self.refreshStatus()
                            try await self.pullReplies()
                            do { try await self.fetchSnapshot() } catch let e as FSError where e.code == "no_snapshot" {}
                            cont.yield(.hello)
                        case "snapshot":
                            for n in try await self.fetchSnapshot() {
                                cont.yield(ServerEvent(type: "node.created", node: n, parentID: n.parentID, deviceID: n.deviceID))
                            }
                            cont.yield(.hello)
                            if await Date().timeIntervalSince(self.lastStatus) > 30 { await self.refreshStatus() }
                        case "reply":
                            try await self.pullReplies()
                        case "cache":
                            await self.cacheArrived(j["key"] as? String ?? "")
                        case "keyring":
                            try await self.refreshKeyring()
                        default: break
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    private func cacheArrived(_ key: String) {
        for c in cacheWaiters.removeValue(forKey: key) ?? [] { c.resume() }
    }

    // MARK: reads

    func me() async throws -> (User, Device?) {
        let s = try await ensure()
        return (s.user, s.devices.first { $0.id == creds.deviceID })
    }

    func info() async throws -> ServerInfo {
        let s = try await ensure()
        return ServerInfo(name: s.serverName, version: s.serverVersion, encryptedAtRest: s.encrypted, relayURL: creds.url)
    }

    func stats() async throws -> Stats { try await ensure().stats }
    func devices() async throws -> ([Device], String) { (try await ensure().devices, creds.deviceID) }
    func categories() async throws -> [FSCategory] { try await ensure().categories }

    func list(_ parentID: String?, dirsOnly: Bool) async throws -> Listing {
        let s = try await ensure()
        let pid = (parentID ?? "").isEmpty ? s.user.rootID : parentID!
        guard let parent = s.byID[pid] else { throw FSError(status: 404, code: "not_found", message: "文件夹不存在") }
        let kids = (s.kids[pid] ?? []).filter { !dirsOnly || $0.isDir }.sorted {
            $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Listing(parent: parent, path: s.path(pid), children: kids)
    }

    func node(_ id: String) async throws -> (Node, [Crumb]) {
        let s = try await ensure()
        guard let n = s.byID[id] else { throw FSError(status: 404, code: "not_found", message: "文件不存在") }
        return (n, s.path(id))
    }

    func walk(_ id: String) async throws -> [WalkEntry] {
        let s = try await ensure()
        guard let root = s.byID[id] else { throw FSError(status: 404, code: "not_found", message: "文件不存在") }
        var out = [WalkEntry(node: root, relPath: root.name)]
        var i = 0
        while i < out.count {
            for c in s.kids[out[i].node.id] ?? [] { out.append(WalkEntry(node: c, relPath: out[i].relPath + "/" + c.name)) }
            i += 1
        }
        return out
    }

    private func page(_ s: Snapshot, _ items: [Node], before: Date? = nil) -> [Node] {
        items.filter { before == nil || $0.createdAt < before! }.sorted { $0.createdAt > $1.createdAt }.prefix(500).map(s.located)
    }

    func timeline(before: Date?, category: String?) async throws -> [Node] {
        let s = try await ensure()
        return page(s, s.nodes.filter { n in
            guard n.timeline else { return false }
            switch category ?? "" {
            case "": return true
            case "none": return n.categoryID.isEmpty
            case let c: return n.categoryID == c
            }
        }, before: before)
    }

    func tagged(_ categoryID: String) async throws -> [Node] {
        let s = try await ensure()
        return page(s, s.nodes.filter { $0.categoryID == categoryID })
    }

    func search(_ q: String) async throws -> [Node] {
        let s = try await ensure()
        return page(s, s.nodes.filter { !$0.parentID.isEmpty && $0.name.localizedCaseInsensitiveContains(q) })
    }

    func trashList() async throws -> [Node] {
        let s = try await ensure()
        return s.trash.map(s.located)
    }

    // MARK: changes

    func rename(_ id: String, to name: String) async throws {
        try await op(["t": "patch", "id": id, "name": name]) { $0.update(id) { $0.name = name } }
    }

    func batch(_ action: String, ids: [String], parentID: String?, categoryID: String?) async throws {
        let s = try await ensure()
        let pid = parentID.map { $0.isEmpty ? s.user.rootID : $0 }
        var b: [String: Any] = ["t": "batch", "action": action, "ids": ids]
        if let pid { b["parent_id"] = pid }
        if let categoryID { b["category_id"] = categoryID }
        try await op(b) { snap in
            for id in ids {
                switch action {
                case "trash":
                    if let gone = snap.removeSubtree(id), !snap.trash.contains(where: { $0.id == id }) { snap.trash.insert(gone, at: 0) }
                case "move": if let pid { snap.update(id) { $0.parentID = pid } }
                case "categorize": snap.update(id) { $0.categoryID = categoryID ?? "" }
                default: break
                }
            }
        }
    }

    func createFolder(parentID: String?, name: String) async throws {
        var b: [String: Any] = ["t": "mkdir", "name": name]
        if let parentID { b["parent_id"] = parentID }
        try await op(b, wait: true, timeout: .seconds(120))
        try? await fetchSnapshot()
    }

    func restore(_ id: String) async throws {
        try await op(["t": "restore", "id": id]) { $0.trash.removeAll { $0.id == id } }
    }

    private var purgePolicy: FSError {
        FSError(status: 403, code: "policy", message: "NAS 设置不允许远程彻底删除，请在局域网内操作（文件仍在回收站中）")
    }

    func purge(_ id: String) async throws {
        guard canPurge else { throw purgePolicy }
        try await op(["t": "purge", "id": id]) { $0.trash.removeAll { $0.id == id } }
    }

    func emptyTrash() async throws {
        guard canPurge else { throw purgePolicy }
        try await op(["t": "empty_trash"]) { $0.trash = [] }
    }

    func createCategory(name: String, color: String, icon: String) async throws {
        try await op(["t": "cat_create", "name": name, "color": color, "icon": icon], wait: true, timeout: .seconds(120))
        try? await fetchSnapshot()
    }

    func updateCategory(_ id: String, name: String?, color: String?, icon: String?) async throws {
        var b: [String: Any] = ["t": "cat_update", "id": id]
        if let name { b["name"] = name }
        if let color { b["color"] = color }
        if let icon { b["icon"] = icon }
        try await op(b) { snap in
            guard let i = snap.categories.firstIndex(where: { $0.id == id }) else { return }
            if let name { snap.categories[i].name = name }
            if let color { snap.categories[i].colorHex = color }
            if let icon { snap.categories[i].icon = icon }
        }
    }

    func deleteCategory(_ id: String) async throws {
        try await op(["t": "cat_delete", "id": id]) { $0.categories.removeAll { $0.id == id } }
    }

    func renameDevice(_ id: String, name: String) async throws { try await op(["t": "device_rename", "id": id, "name": name]) }

    func revokeDevice(_ id: String) async throws {
        try await op(["t": "device_revoke", "id": id]) { $0.devices.removeAll { $0.id == id } }
    }

    func logout() async { _ = try? await op(["t": "device_revoke", "id": creds.deviceID]) }

    func createPairingCode() async throws -> (String, Date) {
        let r = try await op(["t": "pair"], wait: true, timeout: .seconds(180))
        let exp = (r["expires"] as? NSNumber)?.doubleValue ?? 0
        return (r["code"] as? String ?? "", Date(timeIntervalSince1970: exp / 1000))
    }

    func changePassword(old: String, new: String, signOutOthers: Bool) async throws { throw FSError.lanOnly() }
    func audit() async throws -> [AuditEntry] { throw FSError.lanOnly() }

    // MARK: transfers

    /// Encrypts a file and uploads the ciphertext (resumable). Returns (blob id, header nonce).
    func uploadBlob(file: URL, size: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> (String, String) {
        var (ring, kid) = creds.keyring
        if ring[kid] == nil { try await refreshKeyring(); (ring, kid) = creds.keyring }
        guard let sk = ring[kid] else { throw FSError(status: 0, code: "key", message: "缺少加密密钥，请重新配对此设备") }
        let enc = try E2E.BlobEncryptor(url: file, size: size, kid: kid, spaceKey: sk)
        let total = enc.length
        let created = try await http.json(http.request("POST", "/r/v1/blobs", json: ["size": total]))
        guard let id = created["id"] as? String else { throw FSError(status: 0, code: "upload", message: "中转站拒绝了上传") }
        var received: Int64 = 0
        var failures = 0
        while received < total {
            try Task.checkCancellation()
            do {
                let end = min(received + (8 << 20), total)
                let start = received
                let data = try await Task.detached(priority: .utility) { try enc.range(start, end) }.value
                let (status, body) = try await http.upload(http.request("PUT", "/r/v1/blobs/\(id)", query: ["offset": String(received)]),
                                                           data: data, progress: { sent in progress((start + sent) * size / max(total, 1)) })
                let j = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                if status == 409, let r = j["received"] as? NSNumber { received = r.int64Value; continue }
                if status >= 400 { throw HTTP.error(status: status, data: body) }
                received = (j["received"] as? NSNumber)?.int64Value ?? received
                failures = 0
            } catch let e as FSError where e.isNetwork && e.code != "canceled" {
                failures += 1
                if failures > 10 { throw e }
                try await Task.sleep(for: .seconds(min(30, 1 << failures)))
                if let st = try? await http.json(http.request("GET", "/r/v1/blobs/\(id)")), let r = st["received"] as? NSNumber {
                    received = r.int64Value
                }
            }
        }
        return (id, enc.nonceB64)
    }

    /// Asks the NAS to take uploaded blobs; resolves once it has.
    func commitUpload(_ body: [String: Any]) async throws -> [String: Any] {
        var b = body
        b["t"] = "upload"
        return try await op(b, wait: true, timeout: .seconds(7200))
    }

    private func cacheKey(_ n: Node) async throws -> String {
        let s = try await ensure()
        if creds.keyring.0[s.kid] == nil { try await refreshKeyring() }
        guard let sk = creds.keyring.0[s.kid] else { throw FSError(status: 0, code: "key", message: "缺少解密密钥，请重新配对此设备") }
        return E2E.cacheKey(sk, nodeID: n.id, sha: n.sha256)
    }

    private func present(_ keys: [String]) async throws -> Set<String> {
        var out = Set<String>()
        for i in stride(from: 0, to: keys.count, by: 2000) {
            let j = try await http.json(http.request("POST", "/r/v1/cache/lookup", json: ["keys": Array(keys[i..<min(i + 2000, keys.count)])]))
            for p in j["present"] as? [[String: Any]] ?? [] { if let k = p["key"] as? String { out.insert(k) } }
        }
        return out
    }

    /// Asks the NAS (in one op) for encrypted copies of files not yet on the relay.
    func prefetch(_ files: [Node]) async throws {
        let now = Date()
        requested = requested.filter { now.timeIntervalSince($0.value) < 600 }
        var keys: [String: String] = [:]
        for n in files { keys[n.id] = try await cacheKey(n) }
        let have = try await present(Array(keys.values))
        let need = files.filter { !have.contains(keys[$0.id]!) && requested[$0.id] == nil }.map(\.id)
        for i in stride(from: 0, to: need.count, by: 5000) {
            let ids = Array(need[i..<min(i + 5000, need.count)])
            try await op(["t": "fetch", "ids": ids])
            for id in ids { requested[id] = now }
        }
    }

    private func waitCached(_ key: String) async throws {
        let deadline = Date().addingTimeInterval(1800)
        while true {
            try Task.checkCancellation()
            if try await present([key]).contains(key) { return }
            if Date() > deadline { throw FSError(status: 0, code: "nas_offline", message: "NAS 长时间未发送该文件（可能离线）") }
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await self.waitForCacheEvent(key) }
                g.addTask { try? await Task.sleep(for: .seconds(8)) }
                await g.next()
                g.cancelAll()
            }
        }
    }

    private func waitForCacheEvent(_ key: String) async {
        await withCheckedContinuation { c in cacheWaiters[key, default: []].append(c) }
    }

    func download(_ n: Node, to: URL, progress: @escaping @Sendable (Int64) -> Void,
                  phase: @escaping @Sendable (String?) -> Void) async throws {
        let total = E2E.cipherSize(n.size)
        let enc = to.appendingPathExtension("fsdownload.enc")
        for attempt in 0..<2 {
            let key = try await cacheKey(n)
            var have = (try? FileManager.default.attributesOfItem(atPath: enc.path)[.size] as? NSNumber)?.int64Value ?? 0
            if have > total { try? FileManager.default.removeItem(at: enc); have = 0 }
            if have < total, try await !present([key]).contains(key) {
                phase("等待 NAS 发送…")
                try await prefetch([n])
                try await waitCached(key)
                phase(nil)
            }
            var failures = 0
            while have < total {
                try Task.checkCancellation()
                do {
                    let base = have
                    let status = try await http.download(
                        http.request("GET", "/r/v1/cache/\(key)", headers: have > 0 ? ["Range": "bytes=\(have)-"] : [:]),
                        to: enc, append: have > 0, progress: { got in progress((base + got) * n.size / max(total, 1)) })
                    if status == 404 {
                        phase("等待 NAS 发送…")
                        requested[n.id] = nil
                        try await prefetch([n])
                        try await waitCached(key)
                        phase(nil)
                    } else if status != 200 && status != 206 {
                        throw FSError(status: status, code: "download", message: "下载失败 (\(status))")
                    }
                    have = (try? FileManager.default.attributesOfItem(atPath: enc.path)[.size] as? NSNumber)?.int64Value ?? 0
                } catch let e as FSError where e.isNetwork && e.code != "canceled" {
                    failures += 1
                    if failures > 8 { throw e }
                    try await Task.sleep(for: .seconds(min(30, 1 << failures)))
                    have = (try? FileManager.default.attributesOfItem(atPath: enc.path)[.size] as? NSNumber)?.int64Value ?? 0
                }
            }
            phase("正在解密校验…")
            let tmp = to.appendingPathExtension("fsdownload")
            let ring = creds.keyring.0
            do {
                try await Task.detached(priority: .utility) {
                    try E2E.decryptFile(src: enc, dst: tmp, size: n.size, ring: ring, sha: n.sha256)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: enc)
                try? FileManager.default.removeItem(at: tmp)
                if attempt == 0 { try await refreshKeyring(); continue }
                throw error
            }
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.moveItem(at: tmp, to: to)
            try? FileManager.default.removeItem(at: enc)
            try? FileManager.default.setAttributes([.modificationDate: n.mtime], ofItemAtPath: to.path)
            phase(nil)
            return
        }
    }

    // MARK: pairing

    /// Enrolls this device with a pairing code; returns once the NAS (on its
    /// next sync) has accepted the request.
    static func pair(code: String, deviceName: String, platform: String,
                     status: @escaping @Sendable (String) -> Void) async throws -> RelayCreds {
        guard let u = URLComponents(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "fileswitch", u.host == "pair",
              let k = u.queryItems?.first(where: { $0.name == "k" })?.value, let secret = Base32.decode(k), secret.count == 16
        else { throw FSError(status: 0, code: "code", message: "请粘贴完整的配对码（以 fileswitch://pair 开头）") }
        let relay = (u.queryItems?.first { $0.name == "r" }?.value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard relay.hasPrefix("https://"), let base = URL(string: relay) else {
            throw FSError(status: 0, code: "code", message: "配对码中的中转站地址无效")
        }
        let fp = u.queryItems?.first { $0.name == "f" }?.value
        let (lookup, key) = E2E.pairing(secret: secret)
        let h = HTTP(base: base, fingerprint: fp)
        defer { h.invalidate() }
        status("正在连接中转站…")
        let req = try E2E.sealEnvelope(key, try JSONSerialization.data(withJSONObject: ["device_name": deviceName, "platform": platform]),
                                       aad: E2E.pairReqAAD(lookup))
        let (st, body) = try await h.raw(h.request("POST", "/r/v1/pair/\(lookup)", json: ["n": req.n, "c": req.c]))
        guard st == 202 else { throw HTTP.error(status: st, data: body) }
        status("等待 NAS 确认（NAS 会在下次同步时处理，通常不超过半分钟）…")
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            guard let (s, d) = try? await h.raw(h.request("GET", "/r/v1/pair/\(lookup)")), s == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let p = try E2E.openEnvelope(key, .init(n: j["n"] as? String ?? "", c: j["c"] as? String ?? ""), aad: E2E.pairRespAAD(lookup))
            guard let creds = RelayCreds(data: p) else { break }
            return creds
        }
        throw FSError(status: 0, code: "timeout", message: "NAS 没有回应。配对码可能已过期或已被使用，也可能 NAS 不在线")
    }
}
