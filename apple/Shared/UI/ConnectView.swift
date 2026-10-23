import SwiftUI

/// Soft moving color field behind glass surfaces.
struct GlassBackdrop: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            .blue.opacity(0.55), .indigo.opacity(0.45), .cyan.opacity(0.4),
            .teal.opacity(0.35), .purple.opacity(0.35), .blue.opacity(0.4),
            .mint.opacity(0.35), .indigo.opacity(0.4), .pink.opacity(0.3),
        ])
        .ignoresSafeArea()
    }
}

struct ConnectView: View {
    enum Step: Hashable { case list, add, login, pair }

    @Environment(AppModel.self) private var model
    @State private var step: Step = .add
    @State private var profile: ServerProfile?
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var deviceName = defaultDeviceName
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var pending: (URL, ServerInfo, String)?
    @State private var showFingerprint = false

    var body: some View {
        ZStack {
            GlassBackdrop()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 6) {
                            Text("FileSwitch").font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("在你的设备之间，私密地交换文件").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 16) {
                            switch step {
                            case .list: listStep
                            case .add: addStep
                            case .login: loginStep
                            case .pair: pairStep
                            }
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.red)
                            }
                        }
                        .padding(26)
                        .frame(maxWidth: 440)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
                        .animation(.snappy, value: step)
                        securityNotes
                    }
                    .padding(24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(isPresented: $showFingerprint) { fingerprintSheet }
        .onAppear(perform: setup)
        .onChange(of: model.pendingPairLink) { takeLink() }
    }

    private func setup() {
        if !model.profiles.isEmpty { step = .list }
        if model.sessionMessage != nil, let id = model.activeID ?? model.profile?.id,
           let p = model.profiles.first(where: { $0.id == id }), !p.url.isEmpty { toLogin(p) }
        takeLink()
    }

    private func takeLink() {
        guard let link = model.pendingPairLink else { return }
        model.pendingPairLink = nil
        code = link
        error = nil
        step = .pair
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var sessionBanner: some View {
        Group {
            if let m = model.sessionMessage {
                Label(m, systemImage: "info.circle.fill").font(.callout)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: steps

    private var listStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("选择交换站", "连接到你 NAS 上的 FileSwitch")
            sessionBanner
            ForEach(model.profiles.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }) { p in
                Button { open(p) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.url.isEmpty ? "cloud.fill" : "externaldrive.fill.badge.wifi")
                            .font(.title3).foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name.isEmpty ? (p.url.isEmpty ? p.relayURL : p.url) : p.name).font(.headline)
                            Text("\(p.username.isEmpty ? "" : p.username + " · ")\(p.url.isEmpty ? "经中转站" : p.url)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                    .padding(12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16, style: .continuous))
                .contextMenu { Button("从本机移除", systemImage: "trash", role: .destructive) { Task { await model.remove(p) } } }
                .disabled(busy)
            }
            HStack {
                Button("添加服务器", systemImage: "plus") { error = nil; step = .add }.buttonStyle(.glass)
                Button("使用配对码", systemImage: "qrcode") { error = nil; step = .pair }.buttonStyle(.glass)
            }
            if busy { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private var addStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("添加交换站", "输入 NAS 的地址，例如 192.168.1.10 或 nas.local:8443")
            TextField("服务器地址", text: $url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit(probe)
            Text("未写端口时默认 8443，未写协议时默认 https").font(.caption).foregroundStyle(.secondary)
            Button(action: probe) {
                Group { if busy { ProgressView().controlSize(.small) } else { Text("连接") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
            HStack {
                Button("不在家？使用配对码", systemImage: "qrcode") { error = nil; step = .pair }
                Spacer()
                if !model.profiles.isEmpty { Button("返回") { step = .list } }
            }
            .buttonStyle(.borderless).font(.callout)
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("登录", "\(profile?.name ?? "") · \(profile?.url ?? "")")
            sessionBanner
            TextField("用户名", text: $username).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("密码", text: $password).textFieldStyle(.roundedBorder).onSubmit(login)
            TextField("设备名称", text: $deviceName).textFieldStyle(.roundedBorder)
            Text("设备名称会显示为文件来源，可随时在「设备与安全」中撤销授权").font(.caption).foregroundStyle(.secondary)
            Button(action: login) {
                Group { if busy { ProgressView().controlSize(.small) } else { Text("登录") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
            HStack {
                if let fp = profile?.fingerprint {
                    Label("证书已固定 \(String(fp.prefix(17)))…", systemImage: "checkmark.shield.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("选择其他服务器") { model.sessionMessage = nil; step = model.profiles.isEmpty ? .add : .list }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
    }

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("使用配对码", "经公网中转站连接 NAS，全程端到端加密")
            TextEditor(text: $code)
                .font(.system(.footnote, design: .monospaced))
                .frame(height: 78)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if code.isEmpty { Text("fileswitch://pair?k=…").font(.footnote.monospaced()).foregroundStyle(.tertiary).padding(12) }
                }
            TextField("设备名称", text: $deviceName).textFieldStyle(.roundedBorder)
            Text("在已登录设备的「设备与安全 → 添加新设备」中生成（手机可直接扫二维码），或在 NAS 上执行 fileswitch pair <用户名>。15 分钟内有效，只能用一次。")
                .font(.caption).foregroundStyle(.secondary)
            if busy, let status {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.caption) }
            }
            Button(action: pair) { Text("配对").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(busy || code.isEmpty)
            Button("返回") { step = model.profiles.isEmpty ? .add : .list }.buttonStyle(.borderless).font(.callout).disabled(busy)
        }
    }

    private var securityNotes: some View {
        HStack(spacing: 18) {
            note("lock.fill", "TLS 1.3 + 证书固定")
            note("lock.rectangle.stack.fill", "端到端加密中转")
            note("person.badge.key.fill", "设备级授权")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func note(_ s: String, _ t: String) -> some View { Label(t, systemImage: s) }

    private var fingerprintSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("验证服务器身份", systemImage: "checkmark.shield").font(.title2.bold())
            Text("首次连接「\(pending?.1.name ?? "")」。它使用自签名证书，请确认下面的指纹与 NAS 启动日志里的「TLS 证书指纹」完全一致：")
                .fixedSize(horizontal: false, vertical: true)
            let parts = (pending?.2 ?? "").split(separator: ":")
            Text(stride(from: 0, to: parts.count, by: 8).map { parts[$0..<min($0 + 8, parts.count)].joined(separator: ":") }.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            Text("信任后指纹会被固定；以后证书若被替换（例如中间人攻击），客户端会拒绝连接。在 NAS 上可用 docker logs fileswitch 查看。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showFingerprint = false; pending = nil }.buttonStyle(.glass)
                Button("指纹一致，信任") {
                    showFingerprint = false
                    if let p = pending { trust(p.0, p.1, p.2) }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 520)
        .presentationDetents([.medium])
    }

    // MARK: actions

    private func open(_ p: ServerProfile) {
        if model.hasCredentials(p) {
            busy = true
            Task { await model.resume(p); busy = false }
        } else {
            toLogin(p)
        }
    }

    private func toLogin(_ p: ServerProfile) {
        profile = p
        username = p.username
        password = ""
        if !p.deviceName.isEmpty { deviceName = p.deviceName }
        step = .login
    }

    func probe() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (base, info, fp) = try await DirectBackend.probe(url)
                if let fp { pending = (base, info, fp); showFingerprint = true } else { trust(base, info, nil) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func trust(_ base: URL, _ info: ServerInfo, _ fp: String?) {
        var p = model.profiles.first { $0.url == base.absoluteString } ?? ServerProfile(id: Data.random(8).hex, name: info.name, url: base.absoluteString)
        p.name = info.name
        p.fingerprint = fp
        toLogin(p)
    }

    func login() {
        guard let p = profile else { return }
        guard !username.isEmpty, !password.isEmpty else { error = "请输入用户名和密码"; return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await model.login(p, username: username, password: password, deviceName: deviceName) } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func pair() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.pair(code: code, deviceName: deviceName) { s in Task { @MainActor in status = s } }
            } catch { self.error = error.localizedDescription }
        }
    }

}
