import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.ready {
                ProgressView()
            } else if !model.signedIn {
                ConnectView()
            } else {
                MainView()
            }
        }
        .overlay { ToastOverlay() }
        .modifier(ActionHost())
    }
}

struct MainView: View {
    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            DetailView()
        }
        #else
        PhoneTabs()
        #endif
    }
}

struct DetailView: View {
    @Environment(Nav.self) private var nav

    var body: some View {
        switch nav.section ?? .files {
        case .files, .categories: FilesView()
        case .timeline: TimelineView()
        case .category(let id): CategoryView(categoryID: id).id(id)
        case .trash: TrashView()
        case .transfers: TransfersView()
        case .settings: SettingsView()
        }
    }
}

#if os(macOS)
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Transfers.self) private var transfers
    @Bindable private var nav = Nav.shared

    var body: some View {
        List(selection: $nav.section) {
            Section("资料库") {
                Label("全部文件", systemImage: "folder").tag(SectionID.files)
                Label("时间线", systemImage: "clock").tag(SectionID.timeline)
            }
            Section {
                ForEach(model.categories) { c in
                    CategoryRow(category: c).tag(SectionID.category(c.id))
                }
            } header: {
                HStack {
                    Text("分类")
                    Spacer()
                    Button { ActionCenter.shared.editCategory(nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("新建分类")
                }
            }
            Section {
                Label("传输", systemImage: "arrow.up.arrow.down")
                    .badge(transfers.activeCount)
                    .tag(SectionID.transfers)
                Label("回收站", systemImage: "trash").tag(SectionID.trash)
                Label("设备与安全", systemImage: "lock.shield").tag(SectionID.settings)
            }
        }
        .safeAreaInset(edge: .bottom) { AccountFooter().padding(10) }
    }
}

/// A category in the sidebar: files dropped on it upload into the category.
struct CategoryRow: View {
    let category: FSCategory
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            CategoryMark(category: category).frame(width: 18)
            Text(category.name).lineLimit(1)
            Spacer()
            if category.count > 0 { Text("\(category.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.vertical, 1)
        .background(targeted ? category.color.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
        .dropDestination(for: URL.self) { urls, _ in
            Transfers.shared.upload(urls, categoryID: category.id, destination: category.name)
            AppModel.shared.toast("已开始上传 \(urls.count) 项到「\(category.name)」")
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("编辑分类", systemImage: "pencil") { ActionCenter.shared.editCategory(category) }
            Button("删除分类", systemImage: "trash", role: .destructive) { ActionCenter.shared.deleteCategory(category) }
        }
    }
}
#endif

/// Account and connection status (replaces a logo block): who, where, how connected.
struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.info?.name ?? model.profile?.name ?? "FileSwitch").font(.callout.weight(.semibold)).lineLimit(1)
                ConnectionBadge()
            }
            Spacer(minLength: 0)
            Menu {
                Text(model.user?.username ?? model.profile?.username ?? "")
                Divider()
                Button("切换服务器", systemImage: "arrow.left.arrow.right") { model.detach() }
                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { Task { await model.signOut() } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

#if os(iOS)
struct PhoneTabs: View {
    @Environment(Transfers.self) private var transfers
    @Bindable private var nav = Nav.shared
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("文件", systemImage: "folder", value: 0) { NavigationStack { FilesView() } }
            Tab("时间线", systemImage: "clock", value: 1) { NavigationStack { TimelineView() } }
            Tab("分类", systemImage: "tag", value: 2) { NavigationStack { CategoriesGrid() } }
            Tab("传输", systemImage: "arrow.up.arrow.down", value: 3) { NavigationStack { TransfersView() } }
                .badge(transfers.activeCount)
            Tab("我的", systemImage: "person.crop.circle", value: 4) { NavigationStack { SettingsView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: nav.section) { _, s in
            switch s {
            case .files: tab = 0
            case .timeline: tab = 1
            case .category, .categories: tab = 2
            case .transfers: tab = 3
            case .settings: tab = 4
            default: break
            }
        }
        .onAppear {
            #if DEBUG
            if let t = ProcessInfo.processInfo.environment["FS_DEMO_TAB"], let i = Int(t) { tab = i }
            #endif
        }
    }
}

/// Phone: categories as a grid of glass tiles.
struct CategoriesGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(model.categories) { c in
                    NavigationLink { CategoryView(categoryID: c.id) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            if c.icon.isEmpty { Image(systemName: "tag.fill").font(.title2).foregroundStyle(c.color) } else { Text(c.icon).font(.largeTitle) }
                            Spacer(minLength: 0)
                            Text(c.name).font(.headline).foregroundStyle(.primary)
                            Text("\(c.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular.tint(c.color.opacity(0.22)).interactive(), in: .rect(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            if model.categories.isEmpty {
                EmptyState(symbol: "tag", title: "还没有分类", hint: "分类用来快速投递与整理文件")
            }
        }
        .background { GlassBackdrop().opacity(0.35) }
        .navigationTitle("分类")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建分类", systemImage: "plus") { ActionCenter.shared.editCategory(nil) }
            }
        }
    }
}
#endif
