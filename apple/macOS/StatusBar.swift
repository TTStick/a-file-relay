import AppKit
import ServiceManagement
import SwiftUI

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusBar.shared.setup()
        Task { @MainActor in
            if !AppModel.shared.ready { await AppModel.shared.start() }
            #if DEBUG
            DemoHooks.afterStart()
            #endif
        }
        // The main window closing keeps FileSwitch in the menu bar; hide it from the Dock then.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard (n.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true else { return }
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { StatusBar.shared.openMain() }
        return true
    }
}

/// Captures SwiftUI's openWindow so AppKit (the status item) can reopen the main window.
struct WindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            StatusBar.shared.openWindow = { openWindow(id: "main") }
        }
    }
}

/// Menu-bar item. While files are dragged anywhere on screen it watches the
/// cursor; near the icon (or the top-right corner, when the icon hides behind
/// the notch) it opens a Liquid Glass panel with one drop target per category.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    static let shared = StatusBar()

    var openWindow: (() -> Void)?
    private var item: NSStatusItem?
    private var panel: DropPanel?
    private var watch: Timer?
    private var dragStart = 0
    private var fileDrag = false
    private var progressTimer: Timer?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: "FileSwitch")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            b.toolTip = "FileSwitch — 把文件拖到这里投递"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        panel = DropPanel()
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
    }

    private func updateProgress() {
        if let p = Transfers.shared.uploadProgress {
            item?.button?.title = " \(Int(p * 100))%"
        } else if item?.button?.title.isEmpty == false {
            item?.button?.title = ""
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = AppModel.shared
        let head = NSMenuItem(title: m.signedIn ? "\(m.info?.name ?? "FileSwitch") · \(m.backend?.modeLabel ?? "")" : "FileSwitch · 未登录",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if Transfers.shared.activeCount > 0 {
            add(menu, "正在传输 \(Transfers.shared.activeCount) 项", #selector(openTransfers))
        }
        menu.addItem(.separator())
        add(menu, "打开 FileSwitch", #selector(openMainAction), key: "o")
        add(menu, "投递面板", #selector(openPanel))
        add(menu, "传输列表", #selector(openTransfers))
        menu.addItem(.separator())
        add(menu, "退出 FileSwitch", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc private func openMainAction() { openMain() }

    func openMain() {
        panel?.hide()
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
        NSApp.activate()
    }

    @objc private func openTransfers() {
        openMain()
        Nav.shared.section = .transfers
    }

    @objc private func openPanel() { DispatchQueue.main.async { self.showPanel(manual: true) } }

    #if DEBUG
    func demoPanel() -> NSWindow? { showPanel(manual: true); return panel }
    #endif
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: drag detection

    private func mouseDown() {
        if let p = panel, p.isVisible, p.manual, !p.frame.contains(NSEvent.mouseLocation) { p.hide() }
        dragStart = NSPasteboard(name: .drag).changeCount
        fileDrag = false
        watch?.invalidate()
        // Poll while the button is held: drags owned by other apps don't reliably
        // deliver events to global monitors. Mouse monitoring needs no permission.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            watch?.invalidate()
            watch = nil
            let was = fileDrag
            fileDrag = false
            if was, let p = panel, p.isVisible, !p.manual {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if !p.holding && !p.manual { p.hide() } }
            }
            return
        }
        if !fileDrag {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragStart, pb.types?.contains(.fileURL) == true else { return }
            fileDrag = true
        }
        if let p = panel, !p.isVisible, nearTray(NSEvent.mouseLocation) { showPanel(manual: false) }
    }

    private func trayFrame() -> NSRect? {
        guard let w = item?.button?.window, let s = w.screen, s.frame.intersects(w.frame), w.frame.width > 0 else { return nil }
        return w.frame
    }

    private func nearTray(_ p: NSPoint) -> Bool {
        if let f = trayFrame(), NSRect(x: f.minX - 160, y: f.minY - 100, width: f.width + 320, height: f.height + 104).contains(p) {
            return true
        }
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        return NSRect(x: s.frame.maxX - 300, y: s.frame.maxY - 60, width: 300, height: 60).contains(p)
    }

    private func showPanel(manual: Bool) {
        guard let panel else { return }
        let size = panel.prepare()
        var origin: NSPoint
        if let f = trayFrame(), let vf = item?.button?.window?.screen?.visibleFrame {
            origin = NSPoint(x: f.midX - size.width / 2, y: vf.maxY - size.height - 8)
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        } else {
            let p = NSEvent.mouseLocation
            let vf = (NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
            origin = NSPoint(x: vf.maxX - size.width - 8, y: vf.maxY - size.height - 8)
        }
        panel.present(at: origin, manual: manual)
    }
}

/// Borderless floating panel hosting the SwiftUI drop targets on Liquid Glass.
@MainActor
final class DropPanel: NSPanel {
    private(set) var manual = false
    var holding = false
    private let host: NSHostingView<AnyView>
    private let glass = NSGlassEffectView()

    init() {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        glass.cornerRadius = 24
        glass.contentView = host
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { hide() }

    /// Rebuilds the content for the current categories and returns its size.
    func prepare() -> NSSize {
        holding = false
        host.rootView = AnyView(DropPanelView(onDropped: { [weak self] in self?.dropped() }, onClose: { [weak self] in self?.hide() })
            .environment(AppModel.shared))
        let size = host.fittingSize
        setContentSize(size)
        return size
    }

    func present(at origin: NSPoint, manual: Bool) {
        self.manual = manual
        setFrameOrigin(origin)
        alphaValue = 0
        orderFrontRegardless()
        if manual { makeKey() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; animator().alphaValue = 1 }
    }

    func hide() {
        holding = false
        orderOut(nil)
    }

    private func dropped() {
        holding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.holding else { return }
            self.hide()
        }
    }
}

struct DropPanelView: View {
    @Environment(AppModel.self) private var model
    let onDropped: () -> Void
    let onClose: () -> Void
    @State private var sent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.signedIn ? "投递到 \(model.info?.name ?? "交换站")" : "FileSwitch").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            if let sent {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                    Text(sent).font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else if !model.signedIn {
                Button("打开 FileSwitch") { StatusBar.shared.openMain() }.buttonStyle(.glassProminent)
            } else {
                let cols = model.categories.count > 7 ? 3 : 2
                GlassEffectContainer(spacing: 10) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
                        DropTile(name: "全部文件", color: .accentColor, icon: "", symbol: "folder") { drop($0, nil, "全部文件") }
                        ForEach(model.categories) { c in
                            DropTile(name: c.name, color: c.color, icon: c.icon, symbol: nil) { drop($0, c.id, c.name) }
                        }
                    }
                }
                if model.categories.isEmpty {
                    Text("在主窗口侧边栏「分类」处新建分类").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var subtitle: String {
        if !model.signedIn { return "请先登录" }
        if !model.online { return "当前离线 · 恢复连接后上传" }
        return "拖到分类上，松手即上传（文件或文件夹）"
    }

    private func drop(_ urls: [URL], _ category: String?, _ name: String) {
        Transfers.shared.upload(urls, categoryID: category, destination: name)
        withAnimation(.snappy) { sent = "已开始上传 \(urls.count) 项 → \(name)" }
        onDropped()
    }
}

private struct DropTile: View {
    let name: String
    let color: Color
    let icon: String
    let symbol: String?
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 9) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color) } else if icon.isEmpty {
                Circle().fill(color.gradient).frame(width: 10, height: 10)
            } else { Text(icon) }
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .glassEffect(.regular.tint(color.opacity(targeted ? 0.55 : 0.18)).interactive(), in: .rect(cornerRadius: 14, style: .continuous))
        .scaleEffect(targeted ? 1.05 : 1)
        .animation(.snappy(duration: 0.2), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}
