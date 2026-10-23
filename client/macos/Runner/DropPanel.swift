import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications

/// A category as shown in the drop panel (mirrors the Dart side).
struct PanelCategory {
  let id: String  // "" = no category (root folder)
  let name: String
  let color: NSColor
  let icon: String
}

extension NSColor {
  convenience init?(hex: String) {
    guard hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
    self.init(
      srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
  }
}

/// Owns the menu-bar item. While the user drags files anywhere on screen it
/// watches the cursor; once it comes near the menu-bar icon (or the top-right
/// corner of the screen, for when the icon is hidden behind the notch) it opens
/// a panel with one drop target per category. Releasing over a category hands
/// the paths to Dart, which uploads them.
final class TrayController: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
  static let shared = TrayController()

  private var channel: FlutterMethodChannel?
  private weak var window: NSWindow?
  private var statusItem: NSStatusItem?
  private lazy var panel = DropPanel(controller: self)

  private(set) var categories: [PanelCategory] = []
  private(set) var signedIn = false
  private(set) var online = false
  private(set) var serverName = ""
  private var progressText = ""

  private var monitors: [Any] = []
  private var watchTimer: Timer?
  private var dragStartCount = 0
  private var fileDrag = false

  func setup(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    let ch = FlutterMethodChannel(name: "fileswitch/macos", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    channel = ch

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let b = item.button {
      let img = NSImage(systemSymbolName: "tray.and.arrow.up.fill", accessibilityDescription: "FileSwitch")
      img?.isTemplate = true
      b.image = img
      b.imagePosition = .imageLeft
      b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      b.toolTip = "FileSwitch — 把文件拖到这里投递到交换站"
    }
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item

    // Mouse monitors need no Accessibility permission (only key monitors do).
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
      self?.mouseDown()
    }) {
      monitors.append(m)
    }
  }

  // MARK: Dart bridge

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setState":
      let a = call.arguments as? [String: Any] ?? [:]
      signedIn = a["signedIn"] as? Bool ?? false
      online = a["online"] as? Bool ?? false
      serverName = a["server"] as? String ?? ""
      categories = (a["categories"] as? [[String: Any]] ?? []).compactMap { d in
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        return PanelCategory(
          id: id, name: name, color: NSColor(hex: d["color"] as? String ?? "") ?? .systemBlue,
          icon: d["icon"] as? String ?? "")
      }
      if panel.isVisible && !panel.holding { panel.reload() }
      result(nil)
    case "setProgress":
      let a = call.arguments as? [String: Any] ?? [:]
      let active = a["active"] as? Int ?? 0
      let p = a["progress"] as? Double ?? -1
      if active > 0 && p >= 0 {
        let pct = Int(p * 100)
        statusItem?.button?.title = " \(pct)%"
        progressText = "正在上传 \(active) 项 · \(pct)%"
      } else {
        statusItem?.button?.title = ""
        progressText = ""
      }
      result(nil)
    case "notify":
      let a = call.arguments as? [String: Any] ?? [:]
      notify(title: a["title"] as? String ?? "FileSwitch", body: a["body"] as? String ?? "")
      result(nil)
    case "setDockVisible":
      setDock(visible: call.arguments as? Bool ?? true)
      result(nil)
    case "getLaunchAtLogin":
      if #available(macOS 13.0, *) {
        result(SMAppService.mainApp.status == .enabled)
      } else {
        result(false)
      }
    case "setLaunchAtLogin":
      let on = call.arguments as? Bool ?? false
      if #available(macOS 13.0, *) {
        do {
          if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
          result(true)
        } catch {
          result(FlutterError(code: "launch_at_login", message: error.localizedDescription, details: nil))
        }
      } else {
        result(false)
      }
    #if DEBUG
      // Used by the integration test: render the panel offscreen to a PNG.
      case "debugSnapshotPanel":
        let path = call.arguments as? String ?? ""
        showPanel(mode: .manual)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          let ok = self.panel.snapshot(to: path)
          self.panel.hide()
          result(ok)
        }
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notify(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async { self.openMain() }
    completionHandler()
  }

  func drop(category: PanelCategory, paths: [String]) {
    channel?.invokeMethod("drop", arguments: ["categoryId": category.id, "paths": paths])
    panel.dropped(on: category.name, count: paths.count)
  }

  private func setDock(visible: Bool) {
    NSApp.setActivationPolicy(visible ? .regular : .accessory)
    if visible { NSApp.activate(ignoringOtherApps: true) }
  }

  // MARK: Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let title =
      signedIn
      ? (serverName.isEmpty ? "FileSwitch" : serverName) + (online ? "" : "（离线）")
      : "FileSwitch · 未登录"
    let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    if !progressText.isEmpty {
      add(menu, progressText, #selector(openTransfers))
    }
    menu.addItem(.separator())
    add(menu, "打开 FileSwitch", #selector(openMain), key: "o")
    add(menu, "投递面板", #selector(openPanel))
    add(menu, "传输列表", #selector(openTransfers))
    menu.addItem(.separator())
    add(menu, "退出 FileSwitch", #selector(quit), key: "q")
  }

  private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    menu.addItem(item)
  }

  @objc func openMain() {
    panel.hide()
    setDock(visible: true)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc func openTransfers() {
    openMain()
    channel?.invokeMethod("showTransfers", arguments: nil)
  }

  @objc func openPanel() {
    // Let the menu close first so the panel isn't dismissed by its tracking.
    DispatchQueue.main.async { self.showPanel(mode: .manual) }
  }

  @objc func quit() {
    NSApp.terminate(nil)
  }

  // MARK: Drag detection

  private func mouseDown() {
    if panel.isVisible && panel.mode == .manual && !panel.frame.contains(NSEvent.mouseLocation) {
      panel.hide()
    }
    dragStartCount = NSPasteboard(name: .drag).changeCount
    fileDrag = false
    watchTimer?.invalidate()
    // Poll while the button is held: drag sessions owned by other apps don't
    // reliably deliver drag events to global monitors.
    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    watchTimer = t
  }

  private func tick() {
    if NSEvent.pressedMouseButtons & 1 == 0 {
      watchTimer?.invalidate()
      watchTimer = nil
      dragEnded()
      return
    }
    if !fileDrag {
      let pb = NSPasteboard(name: .drag)
      guard pb.changeCount != dragStartCount, pb.types?.contains(.fileURL) == true else { return }
      fileDrag = true
    }
    if !panel.isVisible && isNearTray(NSEvent.mouseLocation) {
      showPanel(mode: .drag)
    }
  }

  private func dragEnded() {
    let was = fileDrag
    fileDrag = false
    guard was, panel.isVisible, panel.mode == .drag else { return }
    // performDragOperation on a tile runs around the same time; give it a moment.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, !self.panel.holding, self.panel.mode == .drag else { return }
      self.panel.hide()
    }
  }

  /// The status item's frame in screen coordinates, if it's actually on screen.
  private func trayFrame() -> NSRect? {
    guard let w = statusItem?.button?.window, let s = w.screen else { return nil }
    let f = w.frame
    return s.frame.intersects(f) && f.width > 0 ? f : nil
  }

  private func isNearTray(_ p: NSPoint) -> Bool {
    if let f = trayFrame() {
      let zone = NSRect(x: f.minX - 160, y: f.minY - 100, width: f.width + 320, height: f.height + 104)
      if zone.contains(p) { return true }
    }
    guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
    return NSRect(x: s.frame.maxX - 300, y: s.frame.maxY - 60, width: 300, height: 60).contains(p)
  }

  private func showPanel(mode: DropPanel.Mode) {
    panel.reload()
    let size = panel.frame.size
    var origin: NSPoint
    if let f = trayFrame(), let screen = statusItem?.button?.window?.screen {
      let vf = screen.visibleFrame
      origin = NSPoint(x: f.midX - size.width / 2, y: vf.maxY - size.height - 6)
      origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
    } else {
      let p = NSEvent.mouseLocation
      let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main
      let vf = screen?.visibleFrame ?? .zero
      origin = NSPoint(x: vf.maxX - size.width - 8, y: vf.maxY - size.height - 6)
    }
    panel.present(at: origin, mode: mode)
  }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

final class DropPanel: NSPanel {
  enum Mode { case drag, manual }

  private(set) var mode: Mode = .drag
  /// True while the "upload started" confirmation is showing.
  private(set) var holding = false
  unowned let controller: TrayController
  private let root = FlippedView()
  private var hideWork: DispatchWorkItem?

  init(controller: TrayController) {
    self.controller = controller
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .popUpMenu
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true

    let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 14
    effect.layer?.masksToBounds = true
    effect.autoresizingMask = [.width, .height]
    contentView = effect
    root.frame = effect.bounds
    root.autoresizingMask = [.width, .height]
    effect.addSubview(root)
  }

  override var canBecomeKey: Bool { true }

  override func cancelOperation(_ sender: Any?) { hide() }

  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor)
    -> NSTextField
  {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
  }

  func reload() {
    hideWork?.cancel()
    holding = false
    root.subviews.forEach { $0.removeFromSuperview() }
    let w: CGFloat = 340
    let pad: CGFloat = 14
    var y: CGFloat = pad

    let name = controller.serverName.isEmpty ? "交换站" : controller.serverName
    let title = label(controller.signedIn ? "投递到 \(name)" : "FileSwitch", size: 14, weight: .semibold)
    title.frame = NSRect(x: pad, y: y, width: w - 2 * pad - 26, height: 19)
    root.addSubview(title)

    let close = NSButton(frame: NSRect(x: w - pad - 20, y: y, width: 20, height: 20))
    close.isBordered = false
    close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
    close.contentTintColor = .tertiaryLabelColor
    close.target = self
    close.action = #selector(hide)
    root.addSubview(close)
    y += 22

    let subText: String
    if !controller.signedIn {
      subText = "请先在 FileSwitch 中登录"
    } else if !controller.online {
      subText = "当前离线 · 文件会在重新连接后上传"
    } else {
      subText = "拖到分类上，松手即上传（文件或文件夹）"
    }
    let sub = label(subText, size: 11, color: .secondaryLabelColor)
    sub.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: 15)
    root.addSubview(sub)
    y += 25

    if !controller.signedIn {
      let b = NSButton(title: "打开 FileSwitch", target: controller, action: #selector(TrayController.openMain))
      b.bezelStyle = .rounded
      b.frame = NSRect(x: pad, y: y, width: 150, height: 28)
      root.addSubview(b)
      y += 34
    } else {
      let items =
        [PanelCategory(id: "", name: "全部文件", color: .controlAccentColor, icon: "")] + controller.categories
      let cols = items.count > 8 ? 3 : 2
      let gap: CGFloat = 8
      let tileW = (w - 2 * pad - CGFloat(cols - 1) * gap) / CGFloat(cols)
      let tileH: CGFloat = cols == 3 ? 50 : 56
      for (i, c) in items.enumerated() {
        let t = TileView(category: c, panel: self)
        t.frame = NSRect(
          x: pad + CGFloat(i % cols) * (tileW + gap), y: y + CGFloat(i / cols) * (tileH + gap),
          width: tileW, height: tileH)
        root.addSubview(t)
      }
      let rows = (items.count + cols - 1) / cols
      y += CGFloat(rows) * (tileH + gap) - gap
      if controller.categories.isEmpty {
        let hint = label("在主窗口侧边栏「分类」处新建分类", size: 11, color: .tertiaryLabelColor)
        hint.frame = NSRect(x: pad, y: y + 8, width: w - 2 * pad, height: 15)
        root.addSubview(hint)
        y += 23
      }
    }
    y += pad
    setContentSize(NSSize(width: w, height: y))
  }

  func present(at origin: NSPoint, mode: Mode) {
    self.mode = mode
    setFrameOrigin(origin)
    alphaValue = 0
    orderFrontRegardless()
    if mode == .manual { makeKey() }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      animator().alphaValue = 1
    }
  }

  #if DEBUG
    func snapshot(to path: String) -> Bool {
      guard let v = contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
      v.cacheDisplay(in: v.bounds, to: rep)
      guard let data = rep.representation(using: .png, properties: [:]) else { return false }
      return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
  #endif

  @objc func hide() {
    hideWork?.cancel()
    holding = false
    orderOut(nil)
  }

  func dropped(on name: String, count: Int) {
    holding = true
    let overlay = NSVisualEffectView(frame: root.bounds)
    overlay.material = .popover
    overlay.blendingMode = .withinWindow
    overlay.state = .active
    overlay.autoresizingMask = [.width, .height]
    let check = NSImageView(
      image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
    check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
    check.contentTintColor = .systemGreen
    let h = root.bounds.height
    check.frame = NSRect(x: (root.bounds.width - 36) / 2, y: h / 2 - 2, width: 36, height: 36)
    let text = label("已开始上传 \(count) 项 → \(name)", size: 13, weight: .medium)
    text.alignment = .center
    text.frame = NSRect(x: 12, y: h / 2 - 26, width: root.bounds.width - 24, height: 18)
    overlay.addSubview(check)
    overlay.addSubview(text)
    root.addSubview(overlay)
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
  }
}

/// One category in the panel; a drop target for file URLs.
final class TileView: NSView {
  let category: PanelCategory
  private weak var panel: DropPanel?
  private var hovering = false {
    didSet { needsDisplay = true }
  }

  init(category: PanelCategory, panel: DropPanel) {
    self.category = category
    self.panel = panel
    super.init(frame: .zero)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("unused") }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    category.color.withAlphaComponent(hovering ? 0.38 : 0.14).setFill()
    path.fill()
    if hovering {
      category.color.setStroke()
      path.lineWidth = 2
      path.stroke()
    }
    let iconRect = NSRect(x: 12, y: (bounds.height - 22) / 2, width: 22, height: 22)
    if category.icon.isEmpty {
      category.color.setFill()
      NSBezierPath(ovalIn: iconRect.insetBy(dx: 5, dy: 5)).fill()
    } else {
      let s = NSAttributedString(string: category.icon, attributes: [.font: NSFont.systemFont(ofSize: 17)])
      let sz = s.size()
      s.draw(at: NSPoint(x: iconRect.midX - sz.width / 2, y: iconRect.midY - sz.height / 2))
    }
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    let name = NSAttributedString(
      string: category.name,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: hovering ? .semibold : .medium),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
      ])
    let h = name.size().height
    name.draw(
      with: NSRect(x: 40, y: (bounds.height - h) / 2, width: bounds.width - 48, height: h),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    hovering = true
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

  override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }

  override func draggingEnded(_ sender: NSDraggingInfo) { hovering = false }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    hovering = false
    let urls =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty else { return false }
    panel?.controller.drop(category: category, paths: urls.map(\.path))
    return true
  }
}
