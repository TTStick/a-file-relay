import SwiftUI
import UniformTypeIdentifiers

/// Newest-first list grouped by day.
struct DayGroupedList: View {
    let items: [Node]
    var showLocation = true

    private var groups: [(String, [Node])] {
        var out: [(String, [Node])] = []
        for n in items {
            let d = Fmt.day(n.createdAt)
            if out.last?.0 == d { out[out.count - 1].1.append(n) } else { out.append((d, [n])) }
        }
        return out
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { day, nodes in
                Section(day) {
                    ForEach(nodes) { n in
                        TimeRow(node: n, showLocation: showLocation)
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { ActionCenter.shared.open(n) }
                            #if os(iOS)
                            .onTapGesture { ActionCenter.shared.open(n) }
                            #endif
                            .contextMenu { NodeMenu(nodes: [n], showLocate: true) }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var items: [Node] = []
    @State private var loaded = false

    var body: some View {
        DayGroupedList(items: items)
            .safeAreaInset(edge: .top, spacing: 0) { chips }
            .overlay {
                if loaded && items.isEmpty {
                    EmptyState(symbol: "clock", title: "还没有投递记录", hint: "上传或拖到菜单栏投递面板的文件，会按时间出现在这里")
                }
            }
            .navigationTitle("时间线")
            #if os(macOS)
            .navigationSubtitle("按投递时间排列的所有文件与文件夹")
            #endif
            .task(id: "\(filter)#\(model.revision)") {
                items = (try? await model.backend?.timeline(before: nil, category: filter)) ?? []
                loaded = true
            }
    }

    /// Filter chips in a Liquid Glass container.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip("全部", id: "", tint: nil, icon: "")
                    ForEach(model.categories) { c in chip(c.name, id: c.id, tint: c.color, icon: c.icon) }
                    chip("未分类", id: "none", tint: nil, icon: "")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder private func chip(_ title: String, id: String, tint: Color?, icon: String) -> some View {
        let selected = filter == id
        let label = HStack(spacing: 5) {
            if !icon.isEmpty { Text(icon) } else if let tint { Circle().fill(tint).frame(width: 8, height: 8) }
            Text(title)
        }
        if selected {
            Button { filter = id } label: { label }.buttonStyle(.glassProminent).tint(tint ?? .accentColor)
        } else {
            Button { filter = id } label: { label }.buttonStyle(.glass)
        }
    }
}

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let categoryID: String
    @State private var items: [Node] = []
    @State private var loaded = false
    @State private var targeted = false
    @State private var showImporter = false

    var body: some View {
        if let c = model.category(categoryID) {
            DayGroupedList(items: items)
                .overlay {
                    if loaded && items.isEmpty {
                        EmptyState(symbol: "tag", title: "「\(c.name)」里还没有文件",
                                   hint: "把文件拖到这里，或拖到侧边栏的分类、菜单栏的投递面板上")
                    }
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(c.color, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .overlay {
                                Label("松手上传到「\(c.name)」", systemImage: "arrow.down.doc").font(.headline)
                                    .padding(.horizontal, 18).padding(.vertical, 10)
                                    .glassEffect(.regular.tint(c.color.opacity(0.35)), in: .capsule)
                            }
                            .padding(8).allowsHitTesting(false)
                    }
                }
                .fileDrop(isTargeted: { targeted = $0 }) { urls in
                    Transfers.shared.upload(urls, categoryID: c.id, destination: c.name)
                    model.toast("已开始上传 \(urls.count) 项到「\(c.name)」")
                }
                .navigationTitle(c.icon.isEmpty ? c.name : "\(c.icon) \(c.name)")
                #if os(macOS)
                .navigationSubtitle("\(c.count) 项")
                #endif
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !c.folderID.isEmpty {
                            Button("打开分类文件夹", systemImage: "folder") { Nav.shared.openFolder(c.folderID) }
                        }
                        Button("编辑分类", systemImage: "pencil") { ActionCenter.shared.editCategory(c) }
                        Button("上传到此分类", systemImage: "arrow.up.circle") { showImporter = true }
                    }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                    if case .success(let urls) = r { Transfers.shared.upload(urls, categoryID: c.id, destination: c.name) }
                }
                .task(id: model.revision) {
                    items = (try? await model.backend?.tagged(c.id)) ?? []
                    loaded = true
                }
        } else {
            EmptyState(symbol: "tag.slash", title: "分类不存在")
        }
    }
}

struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Node] = []
    @State private var canPurge = true
    @State private var confirmEmpty = false
    @State private var purgeTarget: Node?

    var body: some View {
        List {
            if !canPurge {
                Label("经中转站时只能恢复；彻底删除需在局域网内操作（NAS 安全策略）", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { n in
                HStack(spacing: 12) {
                    NodeIcon(node: n, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).lineLimit(1)
                        Text("\(Fmt.subtitle(n)) · 删除于 \(Fmt.time(n.trashedAt ?? n.updatedAt))\(n.location.isEmpty ? "" : " · 原位置 \(n.location)")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("恢复") { run { try await model.backend?.restore(n.id); model.toast("已恢复「\(n.name)」") } }
                        .buttonStyle(.glass)
                    if canPurge {
                        Button("彻底删除", systemImage: "trash.slash", role: .destructive) { purgeTarget = n }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
        }
        .overlay { if items.isEmpty { EmptyState(symbol: "trash", title: "回收站是空的") } }
        .navigationTitle("回收站")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空回收站", systemImage: "trash.slash", role: .destructive) { confirmEmpty = true }
                    .disabled(items.isEmpty || !canPurge)
            }
        }
        .confirmationDialog("清空回收站？其中的项目将被永久删除，无法恢复。", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("清空", role: .destructive) { run { try await model.backend?.emptyTrash() } }
        }
        .confirmationDialog("彻底删除「\(purgeTarget?.name ?? "")」？无法恢复。",
                            isPresented: Binding(get: { purgeTarget != nil }, set: { if !$0 { purgeTarget = nil } }), titleVisibility: .visible) {
            Button("彻底删除", role: .destructive) { if let n = purgeTarget { run { try await model.backend?.purge(n.id) } } }
        }
        .task(id: model.revision) {
            items = (try? await model.backend?.trashList()) ?? []
            canPurge = await model.backend?.canPurge ?? false
        }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task {
            do { try await f() } catch { model.toast(error.localizedDescription) }
            model.revision += 1
        }
    }
}

struct TransfersView: View {
    @Environment(Transfers.self) private var transfers

    var body: some View {
        List {
            ForEach(transfers.items) { t in TransferRow(t: t) }
        }
        .overlay { if transfers.items.isEmpty { EmptyState(symbol: "arrow.up.arrow.down", title: "没有传输任务") } }
        .navigationTitle("传输")
        #if os(macOS)
        .navigationSubtitle("\(transfers.activeCount) 项进行中")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清除已完成", systemImage: "checklist") { transfers.clearFinished() }
                    .disabled(!transfers.items.contains { !$0.active })
            }
        }
    }
}

struct TransferRow: View {
    let t: Transfer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: t.isFolder ? "folder.fill" : (t.kind == .upload ? "arrow.up.doc.fill" : "arrow.down.doc.fill"))
                .font(.title3)
                .foregroundStyle(t.kind == .upload ? Color.accentColor : .teal)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(t.name).font(.body.weight(.medium)).lineLimit(1)
                if t.active {
                    if t.status == .queued || t.phase != nil { ProgressView().progressViewStyle(.linear) } else {
                        ProgressView(value: t.progress)
                    }
                }
                Text(statusLine).font(.caption).foregroundStyle(statusColor).lineLimit(2)
            }
            Spacer()
            if t.active {
                Button("取消", systemImage: "xmark.circle.fill") { Transfers.shared.cancel(t) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            } else {
                if t.kind == .download, t.status == .done, let u = t.localURL {
                    #if os(macOS)
                    Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    #else
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                    #endif
                }
                Button("移除", systemImage: "xmark") { Transfers.shared.remove(t) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        var s: String
        switch t.status {
        case .queued: s = "等待中"
        case .running: s = t.phase ?? "\(Int(t.progress * 100))%\(t.speed > 0 ? "  " + Fmt.bytes(Int64(t.speed)) + "/s" : "")"
        case .done: s = t.kind == .upload ? "已上传" : "已下载"
        case .failed: s = t.error ?? "失败"
        case .canceled: s = "已取消"
        }
        var parts = [s]
        if t.total > 0 { parts.append("\(Fmt.bytes(t.done)) / \(Fmt.bytes(t.total))") }
        if t.isFolder, t.files > 0 { parts.append("\(t.doneFiles)/\(t.files) 个文件") }
        if !t.destination.isEmpty { parts.append("→ \(t.destination)") }
        return parts.joined(separator: "   ")
    }

    private var statusColor: Color {
        switch t.status {
        case .failed: .red
        case .done: .green
        default: .secondary
        }
    }
}
