import Observation
import QuickLook
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// File actions shared by every list. Sheets and alerts hang off the root view.
@MainActor @Observable
final class ActionCenter {
    static let shared = ActionCenter()
    private var model: AppModel { .shared }

    var renameTarget: Node?
    var renameText = ""
    var moveTargets: [Node] = []
    var showMove = false
    var trashTargets: [Node] = []
    var showTrash = false
    var previewURL: URL?
    var newFolderParent: String?
    var showNewFolder = false
    var newFolderName = "新建文件夹"
    var editingCategory: FSCategory?
    var showCategoryEditor = false
    var opening: String?

    private func run(_ f: @escaping () async throws -> Void) {
        Task {
            do { try await f() } catch { model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            model.revision += 1
        }
    }

    func open(_ n: Node) {
        if n.isDir { Nav.shared.openFolder(n.id); return }
        opening = n.name
        Task {
            defer { opening = nil }
            do {
                let url = try await Transfers.shared.fetchToCache(n)
                previewURL = url
            } catch { model.toast((error as? LocalizedError)?.errorDescription ?? "无法打开") }
        }
    }

    #if os(macOS)
    func openWithDefaultApp(_ n: Node) {
        Task {
            do { NSWorkspace.shared.open(try await Transfers.shared.fetchToCache(n)) } catch { model.toast("无法打开 \(n.name)") }
        }
    }
    #endif

    func download(_ nodes: [Node], choose: Bool = false) {
        var dir: URL?
        #if os(macOS)
        if choose {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.prompt = "下载到这里"
            guard p.runModal() == .OK, let u = p.url else { return }
            dir = u
        }
        #endif
        for n in nodes { Transfers.shared.download(n, to: dir) }
        model.toast(nodes.count == 1 ? "开始下载 \(nodes[0].name)" : "开始下载 \(nodes.count) 项")
    }

    func locate(_ n: Node) { Nav.shared.openFolder(n.parentID, highlight: n.id) }

    func rename(_ n: Node) {
        renameText = n.name
        renameTarget = n
    }

    func commitRename() {
        guard let n = renameTarget, !renameText.isEmpty, renameText != n.name else { return }
        let name = renameText
        run { try await self.model.backend?.rename(n.id, to: name) }
    }

    func move(_ nodes: [Node]) {
        moveTargets = nodes
        showMove = true
    }

    func commitMove(to folder: String) {
        let ids = moveTargets.filter { $0.id != folder && $0.parentID != folder }.map(\.id)
        guard !ids.isEmpty else { return }
        run {
            try await self.model.backend?.batch("move", ids: ids, parentID: folder, categoryID: nil)
            self.model.toast("已移动 \(ids.count) 项")
        }
    }

    func setCategory(_ nodes: [Node], _ id: String) {
        run {
            try await self.model.backend?.batch("categorize", ids: nodes.map(\.id), parentID: nil, categoryID: id)
            self.model.toast(id.isEmpty ? "已移除分类" : "已归入「\(self.model.category(id)?.name ?? "")」")
            await self.model.refreshCategories()
        }
    }

    func trash(_ nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        trashTargets = nodes
        showTrash = true
    }

    func commitTrash() {
        let ids = trashTargets.map(\.id)
        run {
            try await self.model.backend?.batch("trash", ids: ids, parentID: nil, categoryID: nil)
            self.model.toast("已移到回收站")
        }
    }

    func newFolder(in parent: String?) {
        newFolderParent = parent
        newFolderName = "新建文件夹"
        showNewFolder = true
    }

    func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if model.viaRelay { model.toast("正在等待 NAS 创建文件夹…") }
        let parent = newFolderParent
        run { try await self.model.backend?.createFolder(parentID: parent, name: name) }
    }

    func editCategory(_ c: FSCategory?) {
        editingCategory = c
        showCategoryEditor = true
    }

    func saveCategory(name: String, color: String, icon: String) {
        let c = editingCategory
        if c == nil && model.viaRelay { model.toast("已提交，等待 NAS 同步后出现…") }
        run {
            if let c { try await self.model.backend?.updateCategory(c.id, name: name, color: color, icon: icon) } else {
                try await self.model.backend?.createCategory(name: name, color: color, icon: icon)
            }
            await self.model.refreshCategories()
        }
    }

    func deleteCategory(_ c: FSCategory) {
        run {
            try await self.model.backend?.deleteCategory(c.id)
            await self.model.refreshCategories()
            if Nav.shared.section == .category(c.id) { Nav.shared.section = .files }
        }
    }
}

/// Context menu for one or more nodes.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let nodes: [Node]
    var showLocate = false
    private var actions: ActionCenter { .shared }

    var body: some View {
        if nodes.count == 1, let n = nodes.first {
            Button(n.isDir ? "打开" : "预览", systemImage: n.isDir ? "folder" : "eye") { actions.open(n) }
            #if os(macOS)
            if !n.isDir { Button("用默认应用打开", systemImage: "arrow.up.forward.app") { actions.openWithDefaultApp(n) } }
            #endif
            if showLocate { Button("打开所在文件夹", systemImage: "scope") { actions.locate(n) } }
        }
        Button("下载", systemImage: "arrow.down.circle") { actions.download(nodes) }
        #if os(macOS)
        Button("下载到…", systemImage: "folder.badge.plus") { actions.download(nodes, choose: true) }
        #endif
        Divider()
        if nodes.count == 1, let n = nodes.first { Button("重命名", systemImage: "pencil") { actions.rename(n) } }
        Button("移动到…", systemImage: "folder") { actions.move(nodes) }
        Menu("设置分类", systemImage: "tag") {
            ForEach(model.categories) { c in
                Button { actions.setCategory(nodes, c.id) } label: { Text(c.icon.isEmpty ? c.name : "\(c.icon) \(c.name)") }
            }
            Divider()
            Button("移除分类") { actions.setCategory(nodes, "") }
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { actions.trash(nodes) }
    }
}

/// Attaches the shared sheets and alerts.
struct ActionHost: ViewModifier {
    @Bindable var actions = ActionCenter.shared

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(get: { actions.renameTarget != nil }, set: { if !$0 { actions.renameTarget = nil } })) {
                TextField("名称", text: $actions.renameText)
                Button("取消", role: .cancel) {}
                Button("重命名") { actions.commitRename() }
            }
            .alert("新建文件夹", isPresented: $actions.showNewFolder) {
                TextField("名称", text: $actions.newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") { actions.commitNewFolder() }
            }
            .confirmationDialog(actions.trashTargets.count == 1 ? "将「\(actions.trashTargets.first?.name ?? "")」移到回收站？"
                                : "将选中的 \(actions.trashTargets.count) 项移到回收站？",
                                isPresented: $actions.showTrash, titleVisibility: .visible) {
                Button("移到回收站", role: .destructive) { actions.commitTrash() }
            }
            .sheet(isPresented: $actions.showMove) { FolderPicker { actions.commitMove(to: $0) } }
            .sheet(isPresented: $actions.showCategoryEditor) { CategoryEditor(existing: actions.editingCategory) }
            .quickLookPreview($actions.previewURL)
            .overlay(alignment: .top) {
                if let name = actions.opening {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在打开 \(name)…").font(.callout) }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 12)
                }
            }
    }
}

/// Browse folders and pick a destination.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void
    @State private var listing: Listing?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let l = listing {
                    ForEach(l.children) { c in
                        Button { Task { await load(c.id) } } label: {
                            Label(c.name, systemImage: "folder.fill").foregroundStyle(.primary)
                        }
                    }
                    if l.children.isEmpty { Text("没有子文件夹").foregroundStyle(.secondary) }
                } else if let error { Text(error) } else { ProgressView() }
            }
            .navigationTitle(listing.map { $0.path.count <= 1 ? "全部文件" : $0.parent.name } ?? "移动到")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if let l = listing, l.path.count > 1 {
                    ToolbarItem(placement: .navigation) {
                        Button("上一级", systemImage: "chevron.left") { Task { await load(l.path[l.path.count - 2].id) } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("移到这里") {
                        if let id = listing?.parent.id { onPick(id) }
                        dismiss()
                    }
                    .disabled(listing == nil)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .task { await load(nil) }
    }

    private func load(_ id: String?) async {
        do { listing = try await model.backend?.list(id, dirsOnly: true) } catch { self.error = error.localizedDescription }
    }
}

struct CategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: FSCategory?
    @State private var name = ""
    @State private var icon = ""
    @State private var color = categoryPalette[0]

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name, prompt: Text("如：照片、工作、临时"))
                TextField("图标（可选，一个 emoji）", text: $icon)
                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 5), spacing: 12) {
                        ForEach(categoryPalette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex).gradient)
                                .frame(width: 28, height: 28)
                                .overlay { if hex == color { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                                .onTapGesture { color = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if existing == nil {
                    Text("投递到该分类的文件会放进根目录下同名的文件夹，并打上分类标签。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "新建分类" : "编辑分类")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        ActionCenter.shared.saveCategory(name: name.trimmingCharacters(in: .whitespaces), color: color,
                                                         icon: String(icon.prefix(2)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .onAppear {
            if let e = existing { name = e.name; icon = e.icon; color = e.colorHex }
            else { color = categoryPalette[AppModel.shared.categories.count % categoryPalette.count] }
        }
    }
}
