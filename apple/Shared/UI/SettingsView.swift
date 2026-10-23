import CoreImage.CIFilterBuiltins
import SwiftUI
#if os(macOS)
import AppKit
import ServiceManagement
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [Device] = []
    @State private var current = ""
    @State private var stats = Stats()
    @State private var audit: [AuditEntry] = []
    @State private var showPair = false
    @State private var showPassword = false
    @State private var revokeTarget: Device?
    @State private var renameTarget: Device?
    @State private var renameText = ""
    @State private var launchAtLogin = false
    @AppStorage("downloadDir") private var downloadDir = ""

    var body: some View {
        Form {
            Section("当前连接") {
                LabeledContent {
                    Text(model.profile?.url.isEmpty == false ? model.profile!.url : model.profile?.relayURL ?? "").foregroundStyle(.secondary)
                } label: {
                    Label(model.info?.name ?? "", systemImage: "externaldrive.connected.to.line.below")
                }
                LabeledContent {
                    ConnectionBadge()
                } label: {
                    Label("连接方式", systemImage: model.viaRelay ? "cloud" : "wifi")
                }
                Text(connectionNote).font(.footnote).foregroundStyle(.secondary)
                LabeledContent("静态加密") {
                    let on = model.info?.encryptedAtRest == true
                    Text("\(Image(systemName: on ? "lock.fill" : "lock.open")) \(on ? "已开启 · AES-256-GCM" : "未开启")")
                }
                if let fp = model.profile?.fingerprint, !model.viaRelay {
                    #if os(macOS)
                    LabeledContent("证书指纹（已固定）") {
                        Text(fp).font(.caption2.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    #else
                    VStack(alignment: .leading, spacing: 4) {
                        Text("证书指纹（已固定）")
                        Text(fp).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    .contextMenu { Button("拷贝", systemImage: "doc.on.doc") { UIPasteboard.general.string = fp } }
                    #endif
                }
                LabeledContent("存储") {
                    Text("\(stats.files) 个文件 · \(stats.folders) 个文件夹 · \(Fmt.bytes(stats.bytes))").foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(devices) { d in
                    HStack(spacing: 10) {
                        Image(systemName: icon(d.platform)).frame(width: 22).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(d.name)
                                if d.relay { Image(systemName: d.remote ? "cloud.fill" : "cloud").font(.caption).foregroundStyle(.secondary).help(d.remote ? "通过配对码加入，只能经中转站访问" : "可经中转站访问") }
                                if d.id == current { Text("本机").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(.tint.opacity(0.18), in: .capsule) }
                            }
                            Text("\(platformLabel(d.platform)) · 最近活动 \(Fmt.ago(d.lastSeen)) · \(d.lastIP)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("重命名") { renameText = d.name; renameTarget = d }
                            Button("撤销授权", role: .destructive) { revokeTarget = d }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                    }
                }
                Button("添加新设备", systemImage: "qrcode") { showPair = true }
            } header: {
                Text("已授权的设备")
            } footer: {
                Text("撤销后该设备立即失去访问权限；经中转站的数据会同时换用新的加密密钥。")
            }

            Section("账户安全") {
                if model.viaRelay {
                    Label("修改密码、安全日志和用户管理只能在局域网直连时使用——即使中转站或某台外出的设备出了问题，也无法远程接管 NAS 账号。",
                          systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("修改密码", systemImage: "key") { showPassword = true }
                    DisclosureGroup("最近的安全事件") {
                        ForEach(audit.prefix(30)) { e in
                            HStack {
                                Image(systemName: e.action == "login_failed" ? "exclamationmark.triangle.fill" : "circle.fill")
                                    .font(e.action == "login_failed" ? .caption : .system(size: 5))
                                    .foregroundStyle(e.action == "login_failed" ? .orange : .secondary)
                                Text(auditLabel(e.action) + (e.detail.isEmpty ? "" : " · \(e.detail)"))
                                Spacer()
                                Text("\(Fmt.time(e.at)) · \(e.ip)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("本机") {
                Toggle("其他设备投递新文件时通知我", isOn: Binding(get: { model.notifyIncoming }, set: { model.notifyIncoming = $0 }))
                #if os(macOS)
                LabeledContent("下载位置") {
                    HStack {
                        Text(Transfers.downloadsDir.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("更改…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { downloadDir = u.path }
                        }
                    }
                }
                Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        launchAtLogin = on
                    } catch { model.toast(error.localizedDescription) }
                }))
                #endif
            }

            Section {
                Button("切换服务器", systemImage: "arrow.left.arrow.right") { model.detach() }
                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { Task { await model.signOut() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设备与安全")
        .task(id: model.revision) { await load() }
        .sheet(isPresented: $showPair) { PairingSheet() }
        .sheet(isPresented: $showPassword) { PasswordSheet() }
        .alert("重命名设备", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { if let d = renameTarget { run { try await model.backend?.renameDevice(d.id, name: renameText) } } }
        }
        .confirmationDialog(revokeTarget?.id == current ? "这会让本机退出登录。" : "「\(revokeTarget?.name ?? "")」将立即失去访问权限。",
                            isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }), titleVisibility: .visible) {
            Button("撤销授权", role: .destructive) {
                guard let d = revokeTarget else { return }
                if d.id == current { Task { await model.signOut() } } else { run { try await model.backend?.revokeDevice(d.id) } }
            }
        }
    }

    private var connectionNote: String {
        if model.viaRelay {
            return "经公网中转站 \(model.profile?.relayURL ?? "")。文件内容、文件名、目录和分类都在本机加密后才发出，中转站只能看到密文；NAS 按自己的节奏取件，不对公网开放任何端口。"
        }
        if let r = model.profile?.relayURL, !r.isEmpty { return "在家时直连 NAS；离开家后自动改走中转站 \(r)。" }
        if let r = model.info?.relayURL, !r.isEmpty { return "该 NAS 已配置中转站，正在为本机开通…" }
        return "该 NAS 未配置中转站，只能在局域网内使用。"
    }

    private func load() async {
        guard let b = model.backend else { return }
        if let (d, c) = try? await b.devices() { devices = d; current = c }
        if let s = try? await b.stats() { stats = s }
        if !b.isRemote, let a = try? await b.audit() { audit = a }
        #if os(macOS)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        #endif
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task {
            do { try await f() } catch { model.toast(error.localizedDescription) }
            model.revision += 1
        }
    }

    private func icon(_ p: String) -> String {
        switch p {
        case "macos": "laptopcomputer"
        case "windows": "pc"
        case "android": "candybarphone"
        case "ios": "iphone"
        default: "desktopcomputer"
        }
    }

    private func platformLabel(_ p: String) -> String {
        ["macos": "macOS", "windows": "Windows", "android": "Android", "ios": "iOS", "linux": "Linux"][p] ?? (p.isEmpty ? "未知" : p)
    }

    private func auditLabel(_ a: String) -> String {
        ["login": "登录", "login_failed": "登录失败", "logout": "退出登录", "password_changed": "修改密码", "password_reset": "重置密码",
         "device_revoked": "撤销设备授权", "device_paired": "配对新设备", "pairing_created": "生成配对码", "relay_enrolled": "开通中转访问",
         "space_key_rotated": "轮换中转密钥", "trash_purged": "彻底删除", "trash_emptied": "清空回收站"][a] ?? a
    }
}

/// One-time pairing code with a QR the phone camera can scan.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expires: Date?
    @State private var error: String?
    @State private var copiedChange: Int?

    var body: some View {
        VStack(spacing: 18) {
            Text("添加新设备").font(.title2.bold())
            if let code {
                if let img = qr(code) {
                    Image(decorative: img, scale: 1)
                        .interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(.white, in: .rect(cornerRadius: 16))
                }
                Text("用新手机的相机扫描二维码；或把配对码复制到新设备的「使用配对码」中。").multilineTextAlignment(.center)
                Text(code).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(4).multilineTextAlignment(.center)
                if let expires {
                    Text("\(expires.formatted(date: .omitted, time: .shortened)) 前有效，只能使用一次。配对码相当于一次性钥匙，请勿发给他人。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack {
                    Button("复制配对码", systemImage: "doc.on.doc") { copy(code) }
                    .buttonStyle(.glass)
                    Button("完成") { dismiss() }.buttonStyle(.glassProminent)
                }
            } else if let error {
                Label(error, systemImage: "lock.shield").multilineTextAlignment(.center)
                Button("知道了") { dismiss() }.buttonStyle(.glassProminent)
            } else {
                ProgressView(model.viaRelay ? "正在请求 NAS 生成配对码（最长约一个同步周期）…" : "正在生成…")
            }
        }
        .padding(28)
        .frame(minWidth: 400)
        .task {
            guard let b = model.backend else { return }
            if let r = b as? RelayBackend, await !r.canPair {
                error = "为安全起见，NAS 设置为不允许经中转站添加设备（防止丢失的设备再「复制」出新设备）。\n\n请在家里的局域网内操作，或在 NAS 上执行：fileswitch pair <用户名>"
                return
            }
            do { (code, expires) = try await b.createPairingCode() } catch { self.error = error.localizedDescription }
        }
        .onDisappear(perform: clearCopy)
    }

    // The code is a one-time key: keep it out of clipboard history and sync,
    // and take it back off the clipboard when the sheet closes.
    private func copy(_ code: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pb.declareTypes([.string, concealed], owner: nil)
        pb.setString(code, forType: .string)
        pb.setString("", forType: concealed)
        copiedChange = pb.changeCount
        #else
        UIPasteboard.general.setItems([["public.utf8-plain-text": code]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(10 * 60)])
        copiedChange = UIPasteboard.general.changeCount
        #endif
    }

    private func clearCopy() {
        guard let copiedChange else { return }
        #if os(macOS)
        if NSPasteboard.general.changeCount == copiedChange { NSPasteboard.general.clearContents() }
        #else
        if UIPasteboard.general.changeCount == copiedChange { UIPasteboard.general.items = [] }
        #endif
    }

    private func qr(_ s: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

struct PasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var others = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                SecureField("当前密码", text: $old)
                SecureField("新密码（至少 8 位）", text: $new1)
                SecureField("再次输入新密码", text: $new2)
                Toggle("同时退出其他所有设备", isOn: $others)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("修改密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("修改") {
                        guard new1 == new2 else { error = "两次输入的新密码不一致"; return }
                        Task {
                            do {
                                try await model.backend?.changePassword(old: old, new: new1, signOutOthers: others)
                                model.toast("密码已修改")
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
