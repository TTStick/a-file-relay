import Foundation
import Observation

@MainActor @Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum Status { case queued, running, done, failed, canceled }

    let id = UUID()
    let kind: Kind
    let name: String
    let isFolder: Bool
    let destination: String
    var status: Status = .queued
    var error: String?
    var phase: String?
    var total: Int64 = 0
    var done: Int64 = 0
    var files = 0
    var doneFiles = 0
    var failedFiles = 0
    var speed: Double = 0
    var localURL: URL?
    var task: Task<Void, Never>?
    fileprivate var lastSample = (Date(), Int64(0))

    init(kind: Kind, name: String, isFolder: Bool, destination: String) {
        self.kind = kind; self.name = name; self.isFolder = isFolder; self.destination = destination
    }

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : (status == .done ? 1 : 0) }
    var active: Bool { status == .queued || status == .running }

    fileprivate func sample() {
        let now = Date()
        let dt = now.timeIntervalSince(lastSample.0)
        guard dt >= 0.5 else { return }
        let inst = Double(done - lastSample.1) / dt
        speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4
        lastSample = (now, done)
    }
}

/// Limits concurrent file transfers.
actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { self.limit = limit }
    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
    func run<T: Sendable>(_ f: @Sendable () async throws -> T) async throws -> T {
        await enter()
        defer { Task { self.leave() } }
        return try await f()
    }
}

/// Reports progress to the main actor at most ~8 times a second.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var value: Int64 = 0
    private let apply: @MainActor (Int64) -> Void
    init(_ apply: @escaping @MainActor (Int64) -> Void) { self.apply = apply }
    func callAsFunction(_ v: Int64) {
        lock.lock()
        value = v
        let now = Date()
        let fire = now.timeIntervalSince(last) > 0.12
        if fire { last = now }
        lock.unlock()
        if fire { Task { @MainActor in self.apply(self.current) } }
    }
    var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

private let junk: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".localized"]

@MainActor @Observable
final class Transfers {
    static let shared = Transfers()
    var items: [Transfer] = []
    private let gate = Gate(3)

    var activeCount: Int { items.filter(\.active).count }

    var uploadProgress: Double? {
        let ups = items.filter { $0.kind == .upload && $0.active }
        guard !ups.isEmpty else { return nil }
        let t = ups.reduce(0) { $0 + $1.total }, d = ups.reduce(0) { $0 + $1.done }
        return t == 0 ? 0 : Double(d) / Double(t)
    }

    func clearFinished() { items.removeAll { !$0.active } }

    func cancel(_ t: Transfer) {
        t.task?.cancel()
        if t.status == .queued { t.status = .canceled }
    }

    func remove(_ t: Transfer) {
        if t.active { t.task?.cancel() }
        items.removeAll { $0.id == t.id }
    }

    private func add(_ t: Transfer) -> Transfer {
        items.insert(t, at: 0)
        if items.count > 200 { items.removeLast(items.count - 150) }
        return t
    }

    private func finish(_ t: Transfer, _ error: Error? = nil) {
        if Task.isCancelled || error is CancellationError || (error as? FSError)?.code == "canceled" {
            t.status = .canceled
        } else if let error {
            t.status = .failed
            t.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        } else if t.failedFiles > 0 {
            t.status = .failed
            t.error = t.error ?? "\(t.failedFiles) 个文件失败"
        } else {
            t.status = .done
            t.done = t.total
        }
        t.phase = nil
        AppModel.shared.revision += 1
    }

    // MARK: uploads

    /// Uploads local files/folders to a folder (`parentID`) or a category.
    func upload(_ urls: [URL], parentID: String? = nil, categoryID: String? = nil, destination: String) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let t = add(Transfer(kind: .upload, name: url.lastPathComponent, isFolder: isDir, destination: destination))
            t.task = Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard let b = AppModel.shared.backend else { throw FSError(status: 401, code: "auth", message: "未登录") }
                    if isDir { try await uploadFolder(t, url, b, parentID, categoryID) } else { try await uploadFile(t, url, b, parentID, categoryID) }
                    finish(t)
                } catch { finish(t, error) }
            }
        }
    }

    private func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    private func mtime(_ url: URL) -> Int64 {
        Int64(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000)
    }

    private func entry(_ rel: String, _ blob: String, _ nonce: String, _ size: Int64, _ url: URL) -> [String: Any] {
        ["rel": rel, "blob": blob, "nonce": nonce, "size": size, "mtime": mtime(url)]
    }

    private func uploadFile(_ t: Transfer, _ url: URL, _ b: Backend, _ parentID: String?, _ categoryID: String?) async throws {
        let sz = size(url)
        t.total = sz
        t.files = 1
        let prog = Throttle { [t] v in t.done = v; t.sample() }
        try await gate.run {
            await MainActor.run { t.status = .running }
            if let r = b as? RelayBackend {
                let (blob, nonce) = try await r.uploadBlob(file: url, size: sz, progress: { prog($0) })
                await MainActor.run { t.phase = "等待 NAS 接收…" }
                var op: [String: Any] = ["files": [await self.entry(url.lastPathComponent, blob, nonce, sz, url)]]
                if let parentID { op["parent_id"] = parentID }
                if let categoryID { op["category_id"] = categoryID }
                try Self.check(try await r.commitUpload(op))
            } else if let d = b as? DirectBackend {
                try await d.upload(file: url, size: sz, parentID: parentID, categoryID: categoryID, relPath: url.lastPathComponent,
                                   timeline: true, progress: { prog($0) })
            }
        }
        t.doneFiles = 1
    }

    nonisolated private static func check(_ r: [String: Any]) throws {
        if let failed = r["failed"] as? [String: Any], let (k, v) = failed.first {
            throw FSError(status: 400, code: "nas", message: "\(k): \(v)")
        }
    }

    private func scan(_ dir: URL) -> (files: [(URL, String)], dirs: [String]) {
        var files: [(URL, String)] = [], dirs: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return ([], []) }
        let base = dir.standardizedFileURL.pathComponents.count
        for case let u as URL in en {
            let comps = Array(u.standardizedFileURL.pathComponents.dropFirst(base))
            if comps.contains(where: { junk.contains($0) || $0.hasPrefix("._") }) { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            let rel = comps.joined(separator: "/")
            if v?.isDirectory == true { dirs.append(rel) } else { files.append((u, rel)) }
        }
        return (files, dirs)
    }

    private func uploadFolder(_ t: Transfer, _ dir: URL, _ b: Backend, _ parentID: String?, _ categoryID: String?) async throws {
        t.status = .running
        t.phase = "正在扫描…"
        let (files, dirs) = await Task.detached { await self.scan(dir) }.value
        t.files = files.count
        t.total = files.reduce(0) { $0 + size($1.0) }
        t.phase = nil
        var used = Set<String>()
        for (_, rel) in files {
            let parts = rel.split(separator: "/")
            for i in 1..<max(parts.count, 1) { used.insert(parts[0..<i].joined(separator: "/")) }
        }
        let empty = dirs.filter { d in !used.contains(d) && !dirs.contains { $0.hasPrefix(d + "/") } }
        var progress = [Int64](repeating: 0, count: files.count)
        func track(_ i: Int) -> Throttle {
            Throttle { [t] v in t.done += v - progress[i]; progress[i] = v; t.sample() }
        }

        if let d = b as? DirectBackend {
            let top = try await d.mkdir(parentID: parentID, categoryID: categoryID, name: dir.lastPathComponent, timeline: true, mtime: nil)
            for p in empty { _ = try await d.mkdir(parentID: top, categoryID: nil, path: p) }
            try await withThrowingTaskGroup(of: Void.self) { g in
                for (i, (u, rel)) in files.enumerated() {
                    let prog = track(i)
                    let sz = size(u)
                    g.addTask {
                        do {
                            try await self.gate.run {
                                try await d.upload(file: u, size: sz, parentID: top, categoryID: nil, relPath: rel, timeline: false,
                                                   progress: { prog($0) })
                            }
                            await MainActor.run { t.doneFiles += 1 }
                        } catch is CancellationError { throw CancellationError() } catch {
                            await MainActor.run { t.failedFiles += 1; t.error = "\(rel): \(error.localizedDescription)" }
                        }
                    }
                }
                try await g.waitForAll()
            }
            return
        }
        guard let r = b as? RelayBackend else { return }
        // Relay: encrypt + upload a batch, then have the NAS take it, so the
        // relay never holds more than one batch.
        var folderID: String?
        var start = 0
        repeat {
            var end = start, bytes: Int64 = 0
            while end < files.count && end - start < 500 && (bytes < 2 << 30 || end == start) { bytes += size(files[end].0); end += 1 }
            var entries: [[String: Any]] = []
            try await withThrowingTaskGroup(of: [String: Any]?.self) { g in
                for i in start..<end {
                    let (u, rel) = files[i], sz = size(u), prog = track(i)
                    g.addTask {
                        do {
                            let (blob, nonce) = try await self.gate.run { try await r.uploadBlob(file: u, size: sz, progress: { prog($0) }) }
                            return await self.entry(rel, blob, nonce, sz, u)
                        } catch is CancellationError { throw CancellationError() } catch {
                            await MainActor.run { t.failedFiles += 1; t.error = "\(rel): \(error.localizedDescription)" }
                            return nil
                        }
                    }
                }
                for try await e in g { if let e { entries.append(e) } }
            }
            t.phase = "等待 NAS 接收…"
            var op: [String: Any] = ["files": entries]
            if let folderID {
                op["parent_id"] = folderID
                op["nested"] = true
            } else {
                if let parentID { op["parent_id"] = parentID }
                if let categoryID { op["category_id"] = categoryID }
                op["folder"] = ["name": dir.lastPathComponent, "mtime": mtime(dir)]
                op["dirs"] = empty
            }
            let res = try await r.commitUpload(op)
            folderID = folderID ?? res["folder_id"] as? String
            t.doneFiles += (res["created"] as? NSNumber)?.intValue ?? 0
            if let failed = res["failed"] as? [String: Any], let (k, v) = failed.first {
                t.failedFiles += failed.count
                t.error = "\(k): \(v)"
            }
            t.phase = nil
            start = end
        } while start < files.count
    }

    // MARK: downloads

    static var downloadsDir: URL {
        #if os(macOS)
        if let s = UserDefaults.standard.string(forKey: "downloadDir"), !s.isEmpty { return URL(fileURLWithPath: s) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("FileSwitch")
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")
        #endif
    }

    nonisolated static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let out = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        return out.isEmpty ? "_" : out
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        for i in 1... {
            let cand = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            if !fm.fileExists(atPath: cand.path) { return cand }
        }
        return url
    }

    @discardableResult
    func download(_ n: Node, to dir: URL? = nil) -> Transfer {
        let t = add(Transfer(kind: .download, name: n.name, isFolder: n.isDir, destination: ""))
        t.task = Task {
            do {
                guard let b = AppModel.shared.backend else { throw FSError(status: 401, code: "auth", message: "未登录") }
                let root = dir ?? Self.downloadsDir
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                t.status = .running
                let phase: @Sendable (String?) -> Void = { p in Task { @MainActor in t.phase = p } }
                if !n.isDir {
                    t.total = n.size
                    t.files = 1
                    let target = Self.unique(root.appendingPathComponent(Self.safeName(n.name)))
                    t.localURL = target
                    let prog = Throttle { [t] v in t.done = v; t.sample() }
                    try await gate.run { try await b.download(n, to: target, progress: { prog($0) }, phase: phase) }
                    t.doneFiles = 1
                } else {
                    t.phase = "正在读取目录…"
                    let entries = try await b.walk(n.id)
                    let top = Self.unique(root.appendingPathComponent(Self.safeName(n.name)))
                    t.localURL = top
                    t.phase = nil
                    func local(_ e: WalkEntry) -> URL {
                        e.relPath.split(separator: "/").dropFirst().reduce(top) { $0.appendingPathComponent(Self.safeName(String($1))) }
                    }
                    for e in entries where e.node.isDir { try FileManager.default.createDirectory(at: local(e), withIntermediateDirectories: true) }
                    let files = entries.filter { !$0.node.isDir }
                    t.files = files.count
                    t.total = files.reduce(0) { $0 + $1.node.size }
                    if let r = b as? RelayBackend { try await r.prefetch(files.map(\.node)) }
                    var progress = [Int64](repeating: 0, count: files.count)
                    try await withThrowingTaskGroup(of: Void.self) { g in
                        for (i, e) in files.enumerated() {
                            let target = local(e)
                            let prog = Throttle { [t] v in t.done += v - progress[i]; progress[i] = v; t.sample() }
                            g.addTask {
                                do {
                                    try await self.gate.run { try await b.download(e.node, to: target, progress: { prog($0) }, phase: phase) }
                                    await MainActor.run { t.doneFiles += 1 }
                                } catch is CancellationError { throw CancellationError() } catch {
                                    await MainActor.run { t.failedFiles += 1; t.error = "\(e.relPath): \(error.localizedDescription)" }
                                }
                            }
                        }
                        try await g.waitForAll()
                    }
                }
                finish(t)
            } catch { finish(t, error) }
        }
        return t
    }

    /// Downloads into the cache for preview/open, reusing an earlier copy.
    func fetchToCache(_ n: Node) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileswitch-open/\(n.id)", isDirectory: true)
        let target = dir.appendingPathComponent(Self.safeName(n.name))
        if let s = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(s) == n.size { return target }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = download(n, to: dir)
        await t.task?.value
        guard t.status == .done, let url = t.localURL else { throw FSError(status: 0, code: "download", message: t.error ?? "已取消") }
        return url
    }
}
