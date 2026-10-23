import Foundation
import Observation
import UserNotifications

/// Session state: which NAS we're signed in to, whether we reach it directly
/// on the LAN or through the relay, the account, categories, live events.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var profiles: [ServerProfile] = []
    var activeID: String?
    var ready = false

    var profile: ServerProfile?
    var backend: Backend?
    var user: User?
    var device: Device?
    var info: ServerInfo?
    var categories: [FSCategory] = []
    var online = false
    var relayPending = 0
    var nasSeen: Date?

    /// Bumped on every server change; views reload with `.task(id:)`.
    var revision = 0
    /// Short message for a toast.
    var notice: String?
    /// Shown on the connect screen after the session ended by itself.
    var sessionMessage: String?
    /// A fileswitch://pair link the app was opened with.
    var pendingPairLink: String?

    var notifyIncoming: Bool {
        get { UserDefaults.standard.object(forKey: "notifyIncoming") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyIncoming") }
    }

    var signedIn: Bool { backend != nil }
    var viaRelay: Bool { backend?.isRemote ?? false }

    private var generation = 0
    private var eventTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var incoming: [String: [String]] = [:]
    private var incomingFlush: Task<Void, Never>?

    func category(_ id: String) -> FSCategory? { categories.first { $0.id == id } }
    func category(named name: String) -> FSCategory? { categories.first { $0.name == name } }

    /// Own tag, or the category whose drop folder this is.
    func categoryOf(_ n: Node) -> FSCategory? {
        category(n.categoryID) ?? (n.isDir ? categories.first { $0.folderID == n.id } : nil)
    }

    func toast(_ s: String) { notice = s }

    // MARK: lifecycle

    func start() async {
        let saved = ProfileStore.load()
        profiles = saved.profiles
        activeID = saved.activeID
        if let id = activeID, let p = profiles.first(where: { $0.id == id }), hasCredentials(p) {
            Task { await activate(p) }
        }
        ready = true
    }

    private func persist() { ProfileStore.save(.init(profiles: profiles, activeID: activeID)) }

    func hasCredentials(_ p: ServerProfile) -> Bool { Keychain.token(p.id) != nil || Keychain.relay(p.id) != nil }

    func upsert(_ p: ServerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        persist()
    }

    func remove(_ p: ServerProfile) async {
        if profile?.id == p.id { await signOut() }
        profiles.removeAll { $0.id == p.id }
        Keychain.setToken(p.id, nil)
        Keychain.setRelay(p.id, nil)
        persist()
    }

    func resume(_ p: ServerProfile) async {
        var p = p
        p.lastUsed = Date()
        upsert(p)
        activeID = p.id
        persist()
        await activate(p)
    }

    func login(_ p: ServerProfile, username: String, password: String, deviceName: String) async throws {
        let h = HTTP(base: URL(string: p.url)!, fingerprint: p.fingerprint)
        let token = try await DirectBackend(http: h).login(username: username, password: password,
                                                           deviceName: deviceName, platform: platformName)
        h.invalidate()
        var p = p
        p.username = username
        p.deviceName = deviceName
        p.lastUsed = Date()
        Keychain.setToken(p.id, token)
        upsert(p)
        activeID = p.id
        persist()
        sessionMessage = nil
        await activate(p)
    }

    /// Adds this device through the relay with a pairing code (no LAN needed).
    func pair(code: String, deviceName: String, status: @escaping @Sendable (String) -> Void) async throws {
        let creds = try await RelayBackend.pair(code: code, deviceName: deviceName, platform: platformName, status: status)
        var p = profiles.first { $0.relayURL == creds.url && $0.username == creds.username }
            ?? ServerProfile(id: Data.random(8).hex, name: creds.serverName, url: "")
        p.relayURL = creds.url
        p.username = creds.username
        p.deviceName = deviceName
        p.lastUsed = Date()
        Keychain.setRelay(p.id, creds)
        upsert(p)
        activeID = p.id
        persist()
        sessionMessage = nil
        await activate(p)
    }

    private func relayBackend(_ p: ServerProfile, _ c: RelayCreds) -> RelayBackend {
        let id = p.id
        return RelayBackend(creds: c, onCredsChanged: { Keychain.setRelay(id, $0) }, onLocal: { ev in
            Task { @MainActor in AppModel.shared.localEvent(ev) }
        })
    }

    /// Directly when the NAS answers on the LAN, else through the relay if enrolled.
    private func chooseBackend(_ p: ServerProfile) async -> Backend? {
        let creds = Keychain.relay(p.id)
        if let token = Keychain.token(p.id), !p.url.isEmpty, let url = URL(string: p.url) {
            let direct = DirectBackend(http: HTTP(base: url, fingerprint: p.fingerprint, bearer: token))
            if creds == nil { return direct }
            var r = direct.http.request("GET", "/api/v1/info")
            r.timeoutInterval = 3
            if let (st, _) = try? await direct.http.raw(r), st == 200 { return direct }
            direct.close()
        }
        return creds.map { relayBackend(p, $0) }
    }

    private func activate(_ p: ServerProfile, backend b: Backend? = nil) async {
        var chosen = b
        if chosen == nil { chosen = await chooseBackend(p) }
        guard let b = chosen else {
            sessionLost("请重新登录")
            return
        }
        eventTask?.cancel()
        modeTask?.cancel()
        backend?.close()
        generation += 1
        let gen = generation
        profile = p
        backend = b
        online = false
        relayPending = 0
        await refreshSession(gen)
        guard gen == generation, backend != nil else { return }
        runEvents(gen)
        watchMode(gen)
        if let d = b as? DirectBackend { Task { await ensureRelayEnrollment(p, d) } }
    }

    /// On the LAN: if the NAS has a relay, get credentials to keep working away from home.
    private func ensureRelayEnrollment(_ p: ServerProfile, _ d: DirectBackend) async {
        guard let relay = info?.relayURL, !relay.isEmpty, Keychain.relay(p.id) == nil else { return }
        guard let bundle = try? await d.enrollRelay() else { return }
        let c = RelayCreds(json: bundle)
        Keychain.setRelay(p.id, c)
        var p = p
        p.relayURL = c.url
        upsert(p)
        if profile?.id == p.id { profile = p }
        toast("此设备已开通中转访问：离开家里的网络也能使用")
    }

    /// Back home while on the relay → switch to the faster direct connection.
    private func watchMode(_ gen: Int) {
        modeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard gen == generation, let p = profile, viaRelay, !p.url.isEmpty else { continue }
                if let b = await chooseBackend(p) {
                    if b is DirectBackend, gen == generation { await activate(p, backend: b); return }
                    b.close()
                }
            }
        }
    }

    func refreshSession(_ gen: Int? = nil) async {
        guard let b = backend else { return }
        do {
            let (u, d) = try await b.me()
            if let gen, gen != generation { return }
            user = u
            device = d
            online = true
            info = try await b.info()
            await refreshCategories()
        } catch let e as FSError {
            if e.unauthorized { sessionLost(b.isRemote ? "此设备的中转授权已被撤销" : "登录已失效，请重新登录"); return }
            online = false
        } catch {
            online = false
        }
    }

    func refreshCategories() async {
        guard let b = backend else { return }
        if let c = try? await b.categories() { categories = c }
    }

    private func runEvents(_ gen: Int) {
        eventTask = Task {
            var delay = 1.0
            while !Task.isCancelled, gen == generation, let b = backend {
                do {
                    for try await ev in b.events() {
                        guard gen == generation else { return }
                        delay = 1
                        handle(ev)
                    }
                } catch let e as FSError where e.unauthorized {
                    sessionLost(b.isRemote ? "此设备的中转授权已被撤销" : "登录已失效，请重新登录")
                    return
                } catch {}
                guard gen == generation else { return }
                online = false
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
                // Left home? Continue through the relay if this device can.
                if b is DirectBackend, delay >= 2, let p = profile, let nb = await chooseBackend(p) {
                    if nb is RelayBackend { await activate(p, backend: nb); return }
                    nb.close()
                }
            }
        }
    }

    func reconnectNow() {
        guard let p = profile, signedIn, !online else { return }
        Task { await activate(p) }
    }

    private func handle(_ ev: ServerEvent) {
        switch ev.type {
        case "hello":
            if !online { online = true; Task { await refreshSession() } } else if viaRelay { Task { await refreshCategories() } }
        case "device.revoked":
            if ev.target == device?.id { sessionLost("此设备的授权已被撤销"); return }
        case "category.changed":
            Task { await refreshCategories() }
        case "node.created":
            if let n = ev.node, n.timeline, ev.deviceID != device?.id, notifyIncoming {
                incoming[n.deviceName.isEmpty ? "其他设备" : n.deviceName, default: []].append(n.name)
                incomingFlush = incomingFlush ?? Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    flushIncoming()
                }
            }
        default: break
        }
        revision += 1
    }

    /// From the relay backend: optimistic refreshes, failures, status.
    func localEvent(_ ev: ServerEvent) {
        switch ev.type {
        case "op.failed": toast("NAS 未能执行操作：\(ev.target)"); revision += 1
        case "relay.status":
            if let r = backend as? RelayBackend {
                Task {
                    let s = await r.status()
                    relayPending = s.pending
                    nasSeen = s.nasSeen
                }
            }
        default: revision += 1
        }
    }

    private func flushIncoming() {
        incomingFlush = nil
        for (dev, names) in incoming {
            let c = UNMutableNotificationContent()
            c.title = "来自 \(dev) 的新文件"
            c.body = names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 项"
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                guard ok else { return }
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            }
        }
        incoming = [:]
    }

    private func sessionLost(_ message: String) {
        if let p = profile {
            Keychain.setToken(p.id, nil)
            Keychain.setRelay(p.id, nil)
        }
        clear()
        sessionMessage = message
    }

    private func clear() {
        generation += 1
        eventTask?.cancel()
        modeTask?.cancel()
        backend?.close()
        backend = nil
        user = nil
        device = nil
        info = nil
        categories = []
        online = false
        relayPending = 0
        nasSeen = nil
    }

    func signOut() async {
        if let b = backend { await b.logout() }
        if let p = profile {
            Keychain.setToken(p.id, nil)
            Keychain.setRelay(p.id, nil)
        }
        activeID = nil
        persist()
        clear()
    }

    /// Leave this server without revoking credentials (to switch servers).
    func detach() {
        activeID = nil
        persist()
        clear()
    }

    func openPairLink(_ url: URL) {
        guard url.scheme == "fileswitch", url.host == "pair" else { return }
        if signedIn { toast("收到配对链接。要用它连接另一个交换站，请先在设置中「切换服务器」"); return }
        pendingPairLink = url.absoluteString
    }
}
