import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @State private var listing: Listing?
    @State private var error: String?
    @State private var selection = Set<Node.ID>()
    @State private var sortOrder = [KeyPathComparator(\Node.name, comparator: .localizedStandard)]
    @State private var query = ""
    @State private var results: [Node]?
    @State private var dropTargeted = false
    @State private var showImporter = false
    @State private var importFolders = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var actions: ActionCenter { .shared }
    private var current: String? { nav.folderID }

    private var rows: [Node] {
        let base = results ?? listing?.children ?? []
        let sorted = base.sorted(using: sortOrder)
        return sorted.filter(\.isDir) + sorted.filter { !$0.isDir }
    }

    private var selectedNodes: [Node] { rows.filter { selection.contains($0.id) } }
    private var folderName: String { (listing?.path.count ?? 0) <= 1 ? "全部文件" : listing?.parent.name ?? "" }

    var body: some View {
        content
            .navigationTitle(results != nil ? "搜索" : folderName)
            #if os(macOS)
            .navigationSubtitle(results.map { "\($0.count) 项结果" } ?? subtitle)
            #endif
            .searchable(text: $query, prompt: "搜索全部文件")
            .toolbar { toolbar }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importFolders ? [.folder] : [.item],
                          allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { upload(urls) }
            }
            .task(id: "\(current ?? "")#\(model.revision)") { await load() }
            .task(id: query) { await search() }
    }

    private var subtitle: String {
        guard let l = listing, l.path.count > 1 else { return "\(listing?.children.count ?? 0) 项" }
        return "/" + l.path.dropFirst().map(\.name).joined(separator: "/")
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        #if os(macOS)
        HSplitView {
            FolderTree(currentPath: listing?.path ?? [])
                .frame(minWidth: 170, idealWidth: 220, maxWidth: 340)
            table
                .frame(minWidth: 480)
        }
        #else
        phoneList
        #endif
    }

    #if os(macOS)
    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name, comparator: .localizedStandard) { n in
                HStack(spacing: 9) {
                    NodeIcon(node: n, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(n.name).lineLimit(1)
                        if results != nil, !n.location.isEmpty { Text(n.location).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 340)
            TableColumn("分类") { n in
                if let c = model.categoryOf(n) { CategoryChip(category: c) }
            }
            .width(min: 70, ideal: 100)
            TableColumn("大小", value: \.size) { n in
                Text(Fmt.subtitle(n)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("上传时间", value: \.createdAt) { n in
                Text(Fmt.time(n.createdAt)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("来源") { n in
                Text(n.deviceName).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: Node.ID.self) { ids in
            NodeMenu(nodes: rows.filter { ids.contains($0.id) }, showLocate: results != nil)
        } primaryAction: { ids in
            if let n = rows.first(where: { ids.contains($0.id) }) { actions.open(n) }
        }
        .onDeleteCommand { actions.trash(selectedNodes) }
        .overlay { emptyOrError }
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHint } }
    }
    #endif

    #if os(iOS)
    private var phoneList: some View {
        List {
            ForEach(rows) { n in
                Button { actions.open(n) } label: {
                    HStack(spacing: 12) {
                        NodeIcon(node: n, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.name).lineLimit(1)
                            HStack(spacing: 6) {
                                if let c = model.categoryOf(n) { CategoryChip(category: c) }
                                Text(results != nil ? n.location : "\(Fmt.subtitle(n)) · \(Fmt.time(n.createdAt))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu { NodeMenu(nodes: [n], showLocate: results != nil) }
                .swipeActions {
                    Button("删除", systemImage: "trash", role: .destructive) { actions.trash([n]) }
                    Button("下载", systemImage: "arrow.down.circle") { actions.download([n]) }.tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { emptyOrError }
        .refreshable { await load() }
        .onChange(of: photoItems) { _, items in importPhotos(items) }
    }
    #endif

    @ViewBuilder private var emptyOrError: some View {
        if let error, listing == nil {
            EmptyState(symbol: "exclamationmark.triangle", title: "无法加载", hint: error)
        } else if listing != nil, rows.isEmpty {
            if results != nil {
                EmptyState(symbol: "magnifyingglass", title: "没有找到匹配的文件")
            } else {
                #if os(macOS)
                EmptyState(symbol: "tray.and.arrow.down", title: "这里还是空的", hint: "把文件或文件夹拖到这里即可上传")
                #else
                EmptyState(symbol: "tray.and.arrow.down", title: "这里还是空的", hint: "点右上角 + 上传文件")
                #endif
            }
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 16))
            .overlay {
                Label("松手上传到「\(folderName)」", systemImage: "arrow.down.doc")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .capsule)
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button("上一级", systemImage: "chevron.up") { goUp() }.disabled((listing?.path.count ?? 0) <= 1 || results != nil)
        }
        #else
        if (listing?.path.count ?? 0) > 1, results == nil {
            ToolbarItem(placement: .topBarLeading) { Button("上一级", systemImage: "chevron.backward") { goUp() } }
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button("新建文件夹", systemImage: "folder.badge.plus") { actions.newFolder(in: listing?.parent.id) }
            Menu {
                Button("上传文件…", systemImage: "doc") { importFolders = false; showImporter = true }
                #if os(macOS)
                Button("上传文件夹…", systemImage: "folder") { importFolders = true; showImporter = true }
                #else
                PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                    Label("照片和视频", systemImage: "photo.on.rectangle")
                }
                #endif
            } label: {
                Label("上传", systemImage: "arrow.up.circle")
            }
        }
    }

    // MARK: data

    private func goUp() {
        guard let l = listing, l.path.count > 1 else { return }
        nav.openFolder(l.path[l.path.count - 2].id)
    }

    private func load() async {
        guard let b = model.backend else { return }
        do {
            let l = try await b.list(current, dirsOnly: false)
            listing = l
            error = nil
            if let h = nav.highlight {
                selection = [h]
                nav.highlight = nil
            } else {
                selection = selection.intersection(Set(l.children.map(\.id)))
            }
        } catch {
            self.error = error.localizedDescription
            if current != nil, (error as? FSError)?.status == 404 { nav.folderID = nil }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        results = (try? await model.backend?.search(q)) ?? []
    }

    private func upload(_ urls: [URL]) {
        guard let l = listing, !urls.isEmpty else { return }
        Transfers.shared.upload(urls, parentID: l.parent.id, destination: folderName)
        model.toast("已开始上传 \(urls.count) 项到「\(folderName)」")
    }

    #if os(iOS)
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            var urls: [URL] = []
            for item in items {
                if let f = try? await item.loadTransferable(type: PickedFile.self) { urls.append(f.url) }
            }
            upload(urls)
        }
    }
    #endif
}

#if os(iOS)
/// A photo/video from the picker, copied to a temp file.
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

#if os(macOS)
/// Collapsible folder tree beside the file table.
struct FolderTree: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    let currentPath: [Crumb]
    @State private var root: Node?
    @State private var children: [String: [Node]] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            if let root {
                TreeRow(node: root, title: "全部文件", depth: 0, current: currentPath.last?.id ?? root.id,
                        children: $children, expanded: $expanded, load: load)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: model.revision) {
            if root == nil, let l = try? await model.backend?.list(nil, dirsOnly: true) {
                root = l.parent
                children[l.parent.id] = l.children
                expanded.insert(l.parent.id)
            }
            for id in expanded { await load(id) }
        }
        .onChange(of: currentPath) { _, path in
            for c in path.dropLast() where !expanded.contains(c.id) {
                expanded.insert(c.id)
                Task { await load(c.id) }
            }
        }
    }

    private func load(_ id: String) async {
        if let l = try? await model.backend?.list(id, dirsOnly: true) { children[id] = l.children }
    }
}

private struct TreeRow: View {
    @Environment(Nav.self) private var nav
    let node: Node
    let title: String
    let depth: Int
    let current: String
    @Binding var children: [String: [Node]]
    @Binding var expanded: Set<String>
    let load: (String) async -> Void

    var body: some View {
        let isOpen = expanded.contains(node.id)
        let kids = children[node.id] ?? []
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(node.childCount > 0 || !kids.isEmpty ? 1 : 0)
                .frame(width: 12)
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.snappy) {
                        if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id); Task { await load(node.id) } }
                    }
                }
            Label(title, systemImage: depth == 0 ? "house" : (isOpen ? "folder" : "folder.fill"))
                .lineLimit(1)
                .fontWeight(node.id == current ? .semibold : .regular)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .listRowSeparator(.hidden)
        .listRowBackground(node.id == current ? RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 6) : nil)
        .contentShape(.rect)
        .onTapGesture { nav.openFolder(depth == 0 ? nil : node.id) }
        if isOpen {
            ForEach(kids.filter(\.isDir)) { c in
                TreeRow(node: c, title: c.name, depth: depth + 1, current: current, children: $children, expanded: $expanded, load: load)
            }
        }
    }
}
#endif
