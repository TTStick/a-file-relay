#if DEBUG
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Debug-only automation for test runs (never compiled into Release):
///   FS_DEMO_URL / FS_DEMO_USER / FS_DEMO_PASS / FS_DEMO_FP  sign in on the LAN
///   FS_DEMO_PAIR          pair through the relay with this code
///   FS_DEMO_NAME          device name
///   FS_DEMO_SECTION       files | timeline | settings | transfers | trash | category:<name>
///   FS_DEMO_FOLDER        open the folder with this name
///   FS_DEMO_COMPACT       (iPad) lay out as in a narrow window (split screen, Slide Over)
///   FS_SELFTEST=<file>    run an end-to-end check, write the result as JSON, quit
///   FS_SHOTS=<dir>        (macOS) capture each page and the drop panel as PNGs, quit
///   FS_SHOTS_SEED=<dir>   upload <dir>/root/* to the root and <dir>/<category>/* to that category first
@MainActor
enum DemoHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var started = false

    nonisolated static func log(_ s: String) { FileHandle.standardError.write(Data("[demo] \(s)\n".utf8)) }

    /// Signs in (LAN) or pairs (relay) without touching the UI.
    static func signIn() async {
        let m = AppModel.shared
        guard !m.signedIn else { return }
        let name = env["FS_DEMO_NAME"] ?? defaultDeviceName
        do {
            if let code = env["FS_DEMO_PAIR"] {
                try await m.pair(code: code, deviceName: name) { log($0) }
                log("paired")
            } else if let url = env["FS_DEMO_URL"] {
                let (base, info, fp) = try await DirectBackend.probe(url)
                log("probe ok: \(info.name) fp=\(fp ?? "system-trusted")")
                if let fp, normalizedFingerprint(fp) != normalizedFingerprint(env["FS_DEMO_FP"] ?? "") { log("fingerprint mismatch"); return }
                var p = ServerProfile(id: Data.random(8).hex, name: info.name, url: base.absoluteString)
                p.fingerprint = fp
                try await m.login(p, username: env["FS_DEMO_USER"] ?? "admin", password: env["FS_DEMO_PASS"] ?? "", deviceName: name)
                log("login ok")
            }
        } catch { log("sign-in failed: \(error.localizedDescription)") }
    }

    static func afterStart() {
        guard !started else { return }
        started = true
        log("app started; profiles=\(AppModel.shared.profiles.count) signedIn=\(AppModel.shared.signedIn)")
        Task {
            #if os(macOS)
            if let dir = env["FS_SHOTS"], !AppModel.shared.signedIn {
                try? await Task.sleep(for: .seconds(2))
                if let w = mainWindow() { capture(w, "\(dir)/00_connect.png") }
            }
            #endif
            if env["FS_DEMO_URL"] != nil || env["FS_DEMO_PAIR"] != nil { await signIn() }
            for _ in 0..<600 where !(AppModel.shared.signedIn && AppModel.shared.online && AppModel.shared.info != nil) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            log("session: signedIn=\(AppModel.shared.signedIn) online=\(AppModel.shared.online) mode=\(AppModel.shared.backend?.modeLabel ?? "-")")
            switch env["FS_DEMO_SECTION"] ?? "" {
            case "timeline": Nav.shared.section = .timeline
            case "settings": Nav.shared.section = .settings
            case "transfers": Nav.shared.section = .transfers
            case "trash": Nav.shared.section = .trash
            case let s where s.hasPrefix("category:"):
                let name = String(s.dropFirst(9))
                if let c = AppModel.shared.categories.first(where: { $0.name == name }) { Nav.shared.section = .category(c.id) }
            default: break
            }
            if let name = env["FS_DEMO_FOLDER"],
               let f = (try? await AppModel.shared.backend?.search(name))?.first(where: { $0.isDir && $0.name == name }) {
                Nav.shared.openFolder(f.id)
            }
            if let out = env["FS_SELFTEST"] { await selfTest(out) }
            #if os(macOS)
            if let dir = env["FS_SHOTS"] { await shots(dir) }
            #endif
        }
    }

    #if os(macOS)
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Captures one of this app's own windows; needs no screen-recording permission.
    /// (CGWindowListCreateImage is hidden from Swift on macOS 15+, so look it up.)
    static func capture(_ w: NSWindow, _ path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let img = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(w.windowNumber), 1 | 8)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { log("capture failed: \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        log("shot \(path)")
    }

    static func shots(_ dir: String) async {
        let m = AppModel.shared
        log("categories: \(m.categories.map(\.name))")
        if let seed = env["FS_SHOTS_SEED"] {
            let fm = FileManager.default
            let subs = ((try? fm.contentsOfDirectory(atPath: seed)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            for (i, name) in subs.enumerated() where name != "root" && m.category(named: name) == nil {
                try? await m.backend?.createCategory(name: name, color: categoryPalette[i % categoryPalette.count], icon: "")
            }
            await m.refreshCategories()
            for sub in subs {
                let urls = ((try? fm.contentsOfDirectory(atPath: "\(seed)/\(sub)")) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                    .map { URL(fileURLWithPath: "\(seed)/\(sub)/\($0)") }
                let cat = m.category(named: sub)
                for u in urls {
                    Transfers.shared.upload([u], categoryID: cat?.id, destination: cat?.name ?? "")
                    try? await Task.sleep(for: .milliseconds(700))   // spread the upload times
                }
            }
            try? await waitFor("seed", seconds: 300) { Transfers.shared.activeCount == 0 }
            log("seeded")
        }
        guard let w = mainWindow() else { log("no main window"); exit(1) }
        w.setContentSize(NSSize(width: 1180, height: 740))
        let pages: [(String, SectionID)] = [("01_files", .files), ("02_timeline", .timeline)]
            + m.categories.prefix(1).map { ("03_category", SectionID.category($0.id)) }
            + [("04_transfers", .transfers), ("05_trash", .trash), ("06_settings", .settings)]
        for (name, section) in pages {
            Nav.shared.section = section
            try? await Task.sleep(for: .seconds(2))
            capture(w, "\(dir)/\(name).png")
        }
        Nav.shared.section = .files
        if let p = StatusBar.shared.demoPanel() {
            try? await Task.sleep(for: .seconds(1.5))
            capture(p, "\(dir)/07_panel.png")
        }
        exit(0)
    }
    #endif

    private static func waitFor(_ what: String, seconds: Double = 120, _ cond: @MainActor () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !(await cond()) {
            if Date() > end { throw FSError(status: 0, code: "timeout", message: "timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Upload a folder, find it, download it back and compare, rename, delete.
    static func selfTest(_ out: String) async {
        var steps: [String] = []
        var ok = true
        let m = AppModel.shared
        do {
            guard let b = m.backend else { throw FSError(status: 0, code: "auth", message: "not signed in") }
            steps.append("mode: \(b.modeLabel)")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fs-selftest-\(UUID().uuidString.prefix(6))")
            let src = tmp.appendingPathComponent("原生客户端自测")
            try FileManager.default.createDirectory(at: src.appendingPathComponent("子目录/空目录"), withIntermediateDirectories: true)
            try Data("你好，Liquid Glass".utf8).write(to: src.appendingPathComponent("a.txt"))
            let big = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try big.write(to: src.appendingPathComponent("子目录/b.bin"))
            let cat = m.categories.first { $0.name == "临时" }
            Transfers.shared.upload([src], categoryID: cat?.id, destination: cat?.name ?? "")
            guard let up = Transfers.shared.items.first else { throw FSError(status: 0, code: "x", message: "no transfer") }
            try await waitFor("upload", seconds: 300) { !up.active }
            guard up.status == .done else { throw FSError(status: 0, code: "upload", message: up.error ?? "upload failed") }
            steps.append("uploaded folder: \(up.doneFiles) files")
            var folder: Node?
            try await waitFor("folder visible") {
                folder = (try? await b.search("原生客户端自测"))?.first { $0.isDir }
                return folder != nil
            }
            let walk = try await b.walk(folder!.id)
            let rels = Set(walk.map(\.relPath))
            let want: Set = ["原生客户端自测", "原生客户端自测/a.txt", "原生客户端自测/子目录", "原生客户端自测/子目录/空目录", "原生客户端自测/子目录/b.bin"]
            guard rels == want else { throw FSError(status: 0, code: "walk", message: "tree mismatch: \(rels.sorted())") }
            steps.append("tree verified (empty dir kept, .DS_Store-free)")
            let dl = tmp.appendingPathComponent("dl")
            let t = Transfers.shared.download(folder!, to: dl)
            try await waitFor("download", seconds: 300) { !t.active }
            guard t.status == .done, let root = t.localURL else { throw FSError(status: 0, code: "download", message: t.error ?? "download failed") }
            guard try Data(contentsOf: root.appendingPathComponent("子目录/b.bin")) == big,
                  try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "你好，Liquid Glass",
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("子目录/空目录").path)
            else { throw FSError(status: 0, code: "compare", message: "downloaded content differs") }
            steps.append("downloaded back, byte-identical")
            let file = walk.first { $0.relPath.hasSuffix("a.txt") }!.node
            try await b.rename(file.id, to: "a-已改名.txt")
            try await waitFor("rename confirmed") {
                if let r = b as? RelayBackend, await r.status().pending > 0 { return false }
                return (try? await b.node(file.id).0.name) == "a-已改名.txt"
            }
            steps.append("rename confirmed by NAS")
            try await b.batch("trash", ids: [folder!.id], parentID: nil, categoryID: nil)
            if await b.canPurge {
                try await waitFor("trash") { (try? await b.trashList())?.contains { $0.id == folder!.id } == true }
                try await b.purge(folder!.id)
            } else {
                do { try await b.purge(folder!.id); ok = false; steps.append("ERROR: remote purge allowed") } catch {
                    steps.append("remote purge refused by policy (expected)")
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            steps.append("cleaned up")
        } catch {
            ok = false
            steps.append("FAILED: \(error.localizedDescription)")
        }
        let json = try? JSONSerialization.data(withJSONObject: ["ok": ok, "steps": steps], options: .prettyPrinted)
        try? json?.write(to: URL(fileURLWithPath: out))
        // leave no test device, token or profile behind
        if env["FS_SELFTEST_KEEP"] == nil, let p = m.profile { await m.remove(p) }
        if env["FS_SELFTEST_KEEP"] == nil { exit(ok ? 0 : 1) }
    }
}
#if os(iOS)
/// FS_DEMO_COMPACT: the size class iPadOS gives a narrow window.
struct DemoSizeClass: ViewModifier {
    func body(content: Content) -> some View {
        if DemoHooks.env["FS_DEMO_COMPACT"] != nil {
            content.environment(\.horizontalSizeClass, .compact)
        } else {
            content
        }
    }
}
#endif
#endif
