import Observation
import SwiftUI
import UniformTypeIdentifiers

enum SectionID: Hashable {
    case files, timeline, categories, category(String), trash, transfers, settings
}

/// Which page is showing; lets pages jump to each other ("show in folder").
@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var section: SectionID? = .files
    var folderID: String?
    var highlight: String?

    func openFolder(_ id: String?, highlight h: String? = nil) {
        folderID = id
        highlight = h
        section = .files
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func time(_ d: Date) -> String {
        let cal = Calendar.current
        let hm = d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if cal.isDateInToday(d) { return "今天 \(hm)" }
        if cal.isDateInYesterday(d) { return "昨天 \(hm)" }
        if cal.isDate(d, equalTo: .now, toGranularity: .year) { return d.formatted(.dateTime.month(.defaultDigits).day()) + " \(hm)" }
        return d.formatted(date: .numeric, time: .shortened)
    }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        return d.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
    }

    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
    }

    static func subtitle(_ n: Node) -> String { n.isDir ? "\(n.childCount) 项" : bytes(n.size) }
}

extension Node {
    /// SF Symbol and tint for the file type.
    var symbol: (String, Color) {
        if isDir { return ("folder.fill", .blue) }
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "svg": return ("photo.fill", .green)
        case "mp4", "mov", "mkv", "avi", "m4v", "webm": return ("film.fill", .red)
        case "mp3", "flac", "wav", "aac", "m4a", "ogg": return ("music.note", .pink)
        case "pdf": return ("doc.richtext.fill", .red)
        case "doc", "docx", "pages", "rtf": return ("doc.text.fill", .blue)
        case "xls", "xlsx", "numbers", "csv": return ("tablecells.fill", .green)
        case "ppt", "pptx", "key": return ("rectangle.on.rectangle.angled.fill", .orange)
        case "zip", "rar", "7z", "tar", "gz", "dmg", "iso", "pkg": return ("archivebox.fill", .brown)
        case "md", "txt", "log": return ("doc.plaintext.fill", .gray)
        case "swift", "go", "dart", "js", "ts", "py", "json", "yaml", "yml", "sh", "html", "css": return ("chevron.left.forwardslash.chevron.right", .indigo)
        case "apk", "exe", "msi", "ipa", "app": return ("app.badge.fill", .teal)
        default: return ("doc.fill", .secondary)
        }
    }
}

/// File icon on a soft tinted tile.
struct NodeIcon: View {
    let node: Node
    var size: CGFloat = 32

    var body: some View {
        let (sym, tint) = node.symbol
        Image(systemName: sym)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct CategoryMark: View {
    let category: FSCategory
    var size: CGFloat = 10

    var body: some View {
        if category.icon.isEmpty {
            Circle().fill(category.color.gradient).frame(width: size, height: size)
        } else {
            Text(category.icon).font(.system(size: size + 3))
        }
    }
}

struct CategoryChip: View {
    let category: FSCategory

    var body: some View {
        HStack(spacing: 4) {
            if !category.icon.isEmpty { Text(category.icon).font(.caption2) }
            Text(category.name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .foregroundStyle(category.color)
        .background(category.color.opacity(0.14), in: .capsule)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var hint: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let hint { Text(hint) }
        }
    }
}

/// Where the connection goes: LAN or relay, with NAS sync status.
struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(model.online ? Color.green : .orange).frame(width: 6, height: 6)
            Image(systemName: model.viaRelay ? "cloud" : "wifi").font(.caption2)
            Text(text).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .help(model.viaRelay ? "经公网中转站，内容端到端加密，中转站无法读取" : "与 NAS 在同一网络中直接连接")
    }

    private var text: String {
        guard model.online else { return model.viaRelay ? "正在连接中转站…" : "正在连接 NAS…" }
        var parts = [model.backend?.modeLabel ?? ""]
        if model.viaRelay, let seen = model.nasSeen { parts.append("NAS \(Fmt.ago(seen))同步") }
        if model.relayPending > 0 { parts.append("\(model.relayPending) 项待同步") }
        return parts.joined(separator: " · ")
    }
}

/// Bottom toast in a Liquid Glass capsule.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Bottom on the Mac; top on iPhone, where the tab bar owns the bottom edge.
        #if os(macOS)
        let edge = Edge.bottom
        #else
        let edge = Edge.top
        #endif
        VStack {
            if edge == .bottom { Spacer() }
            if let n = model.notice {
                Text(n)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)
                    .padding(edge == .bottom ? .bottom : .top, edge == .bottom ? 28 : 6)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: edge).combined(with: .opacity))
                    .task(id: n) {
                        try? await Task.sleep(for: .seconds(3.2))
                        withAnimation(.snappy) { if model.notice == n { model.notice = nil } }
                    }
            }
            if edge == .top { Spacer() }
        }
        .animation(.snappy, value: model.notice)
        .allowsHitTesting(false)
    }
}

/// A list row for files in time-ordered lists (timeline, category, search).
struct TimeRow: View {
    @Environment(AppModel.self) private var model
    let node: Node
    var showLocation = true

    var body: some View {
        HStack(spacing: 12) {
            NodeIcon(node: node, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).lineLimit(1)
                    if let c = model.categoryOf(node) { CategoryChip(category: c) }
                }
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        var parts = [node.createdAt.formatted(date: .omitted, time: .shortened), Fmt.subtitle(node)]
        if !node.deviceName.isEmpty { parts.append("来自 \(node.deviceName)") }
        if showLocation && !node.location.isEmpty { parts.append("位于 \(node.location)") }
        return parts.joined(separator: " · ")
    }
}

let categoryPalette = ["#4F7CFF", "#2EAD6B", "#F59E0B", "#E5534B", "#B45FD8", "#14B8A6", "#EC4899", "#64748B", "#8D6E4F", "#0EA5E9"]

extension EnvironmentValues {
    /// Mac, or an iPad window wide enough for the sidebar + tree + table layout.
    @Entry var wideLayout = false
}

#if os(iOS)
/// A file from the photo picker or dropped from another app, copied to a temp
/// file (the original is only readable while the import runs).
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedFile(url: dst)
        }
    }
}
#endif

extension View {
    /// Accepts files and folders dragged in from Finder, or on iPad from Files
    /// and other apps, and hands them over as local URLs.
    func fileDrop(isTargeted: @escaping (Bool) -> Void = { _ in }, perform: @escaping ([URL]) -> Void) -> some View {
        #if os(macOS)
        dropDestination(for: URL.self) { urls, _ in
            perform(urls)
            return true
        } isTargeted: { isTargeted($0) }
        #else
        dropDestination(for: PickedFile.self) { files, _ in
            perform(files.map(\.url))
            return true
        } isTargeted: { isTargeted($0) }
        #endif
    }
}
