import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import 'dialogs.dart';

enum _Mode { list, add, login, pair }

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final s = AppState.instance;
  late _Mode mode = s.config.profiles.isEmpty ? _Mode.add : _Mode.list;
  ServerProfile? profile;
  final urlCtrl = TextEditingController();
  final userCtrl = TextEditingController();
  final pwCtrl = TextEditingController();
  final devCtrl = TextEditingController(text: defaultDeviceName());
  final codeCtrl = TextEditingController();
  bool busy = false;
  String? error;
  String? pairStatus;

  @override
  void initState() {
    super.initState();
    _takeLink(initial: true);
    s.addListener(_takeLink);
    // Came back after the session ended: go straight to that server's login.
    final last = s.profile ?? (s.config.activeId == null ? null : s.profileById(s.config.activeId!));
    if (s.sessionMessage != null && last != null) _toLogin(last);
  }

  @override
  void dispose() {
    s.removeListener(_takeLink);
    super.dispose();
  }

  /// Opened from a fileswitch://pair link (e.g. a QR code scanned by the camera).
  void _takeLink({bool initial = false}) {
    final link = s.pendingPairCode;
    if (link == null || busy) return;
    s.pendingPairCode = null;
    codeCtrl.text = link;
    error = null;
    if (initial) {
      mode = _Mode.pair; // setState isn't allowed during initState
    } else {
      setState(() => mode = _Mode.pair);
    }
  }

  void _toLogin(ServerProfile p) {
    profile = p;
    userCtrl.text = p.username;
    pwCtrl.clear();
    if (p.deviceName.isNotEmpty) devCtrl.text = p.deviceName;
    mode = _Mode.login;
  }

  Future<void> _probe() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await ApiClient.probe(urlCtrl.text);
      if (!mounted) return;
      if (r.url.scheme == 'http') {
        final ok = await confirm(context, '不安全的连接',
            '该地址使用未加密的 HTTP，密码和文件都可能被同一网络中的人窃取。仅建议在测试时使用。', ok: '仍然继续', danger: true);
        if (!ok) return;
      }
      if (r.fingerprint != null && mounted) {
        final ok = await _confirmFingerprint(r);
        if (!ok) return;
      }
      final url = r.url.toString();
      final existing = s.config.profiles.where((p) => p.url == url).firstOrNull;
      final p = existing ??
          ServerProfile(id: List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join(), url: url, name: r.info.name);
      p
        ..name = r.info.name
        ..fingerprint = r.fingerprint;
      setState(() => _toLogin(p));
    } catch (e) {
      setState(() => error = e is ApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirmFingerprint(ProbeResult r) async {
    final fp = r.fingerprint!;
    final groups = <String>[];
    final parts = fp.split(':');
    for (var i = 0; i < parts.length; i += 8) {
      groups.add(parts.sublist(i, min(i + 8, parts.length)).join(':'));
    }
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.verified_user_rounded, size: 36),
        title: const Text('验证服务器身份'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('首次连接「${r.info.name}」。该服务器使用自签名证书，请确认下面的指纹与服务器启动日志中显示的'
                '「TLS 证书指纹」完全一致：'),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(groups.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5)),
            ),
            const SizedBox(height: 12),
            Text('信任后此指纹会被固定。以后如果证书被替换（例如遭遇中间人攻击），客户端会拒绝连接。',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('在 NAS 上查看：docker logs fileswitch 或 docker exec fileswitch fileswitch fingerprint',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: fp)), child: const Text('复制指纹')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('指纹一致，信任')),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _login() async {
    final p = profile;
    if (p == null) return;
    if (userCtrl.text.trim().isEmpty || pwCtrl.text.isEmpty) {
      setState(() => error = '请输入用户名和密码');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await s.login(p, userCtrl.text.trim(), pwCtrl.text, devCtrl.text.trim().isEmpty ? defaultDeviceName() : devCtrl.text.trim());
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pair() async {
    setState(() {
      busy = true;
      error = null;
      pairStatus = null;
    });
    try {
      await s.pairWithCode(codeCtrl.text.trim(), devCtrl.text.trim().isEmpty ? defaultDeviceName() : devCtrl.text.trim(),
          onStatus: (st) {
        if (mounted) setState(() => pairStatus = st);
      });
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : (e is FormatException ? e.message : '$e'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _open(ServerProfile p) async {
    if (await s.hasToken(p)) {
      setState(() => busy = true);
      try {
        await s.resume(p);
      } catch (e) {
        if (mounted) setState(() => _toLogin(p));
      } finally {
        if (mounted) setState(() => busy = false);
      }
    } else {
      setState(() => _toLogin(p));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    final form = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(
              key: ValueKey(mode),
              child: switch (mode) {
                _Mode.list => _list(context),
                _Mode.add => _add(context),
                _Mode.login => _loginForm(context),
                _Mode.pair => _pairForm(context),
              },
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: wide ? Row(children: [const SizedBox(width: 400, child: _Brand()), Expanded(child: form)]) : form,
      ),
    );
  }

  Widget _title(String t, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (MediaQuery.sizeOf(context).width < 860) ...[const _Logo(size: 48), const SizedBox(height: 16)],
        Text(t, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(sub, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 24),
      ]);

  Widget _error() => error == null
      ? const SizedBox()
      : Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        );

  Widget _list(BuildContext context) {
    final profiles = [...s.config.profiles]
      ..sort((a, b) => (b.lastUsed ?? DateTime(0)).compareTo(a.lastUsed ?? DateTime(0)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title('选择交换站', '连接到你 NAS 上的 FileSwitch 服务器'),
      if (s.sessionMessage != null) _banner(s.sessionMessage!),
      for (final p in profiles)
        Card(
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: Text(p.name.isEmpty ? p.url : p.name),
            subtitle: Text(
                '${p.username.isEmpty ? '' : '${p.username} @ '}${p.url.isNotEmpty ? p.url : p.relayUrl}'
                '${p.relayUrl.isNotEmpty ? (p.url.isNotEmpty ? ' · 可经中转站' : ' · 经中转站') : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            trailing: PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'remove' &&
                    await confirm(context, '删除服务器', '从本机移除「${p.name}」？服务器上的文件不受影响。', ok: '删除')) {
                  await s.removeProfile(p);
                  setState(() => mode = s.config.profiles.isEmpty ? _Mode.add : _Mode.list);
                }
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('删除'))],
            ),
            onTap: busy ? null : () => _open(p),
          ),
        ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => setState(() {
          mode = _Mode.add;
          error = null;
        }),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加服务器'),
      ),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: () => setState(() {
          mode = _Mode.pair;
          error = null;
        }),
        icon: const Icon(Icons.qr_code_2_rounded),
        label: const Text('不在家？使用配对码经中转站连接'),
      ),
      if (busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
    ]);
  }

  Widget _add(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title('添加交换站', '输入 NAS 上 FileSwitch 服务的地址'),
      TextField(
        controller: urlCtrl,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '服务器地址',
          hintText: '192.168.1.10 或 nas.example.com:8443',
          helperText: '未写端口时默认使用 8443，未写协议时默认 https',
          prefixIcon: Icon(Icons.link_rounded),
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _probe(),
      ),
      const SizedBox(height: 16),
      _error(),
      FilledButton(
        onPressed: busy ? null : _probe,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('连接'),
      ),
      TextButton.icon(
        onPressed: () => setState(() {
          mode = _Mode.pair;
          error = null;
        }),
        icon: const Icon(Icons.qr_code_2_rounded),
        label: const Text('不在家？使用配对码经中转站连接'),
      ),
      if (s.config.profiles.isNotEmpty)
        TextButton(onPressed: () => setState(() => mode = _Mode.list), child: const Text('返回服务器列表')),
    ]);
  }

  Widget _pairForm(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title('使用配对码', '经公网中转站连接 NAS，全程端到端加密'),
      TextField(
        controller: codeCtrl,
        minLines: 2,
        maxLines: 4,
        autocorrect: false,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          labelText: '配对码',
          hintText: 'fileswitch://pair?k=…',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: devCtrl,
        decoration: const InputDecoration(
          labelText: '设备名称',
          prefixIcon: Icon(Icons.devices_rounded),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      Text('配对码可以在已登录设备的「设备与安全 → 添加新设备」中生成（手机可直接扫描二维码），'
          '或在 NAS 上执行 docker exec fileswitch fileswitch pair <用户名>。配对码 15 分钟内有效，只能使用一次。',
          style: t.bodySmall),
      const SizedBox(height: 16),
      _error(),
      if (pairStatus != null && busy)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(pairStatus!, style: t.bodySmall)),
          ]),
        ),
      FilledButton(
        onPressed: busy ? null : _pair,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('配对'),
      ),
      TextButton(
        onPressed: busy
            ? null
            : () => setState(() {
                  mode = s.config.profiles.isEmpty ? _Mode.add : _Mode.list;
                  error = null;
                }),
        child: const Text('返回'),
      ),
    ]);
  }

  Widget _loginForm(BuildContext context) {
    final p = profile!;
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('登录', '${p.name} · ${p.url}'),
        if (s.sessionMessage != null) _banner(s.sessionMessage!),
        TextField(
          controller: userCtrl,
          autofocus: userCtrl.text.isEmpty,
          autocorrect: false,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(labelText: '用户名', prefixIcon: Icon(Icons.person_rounded), border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: pwCtrl,
          autofocus: userCtrl.text.isNotEmpty,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_rounded), border: OutlineInputBorder()),
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: devCtrl,
          decoration: const InputDecoration(
            labelText: '设备名称',
            helperText: '在其他设备上显示为文件来源，可随时撤销该设备的授权',
            prefixIcon: Icon(Icons.devices_rounded),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 16),
        _error(),
        FilledButton(
          onPressed: busy ? null : _login,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('登录'),
        ),
        TextButton(
          onPressed: () => setState(() {
            mode = s.config.profiles.isEmpty ? _Mode.add : _Mode.list;
            error = null;
            s.sessionMessage = null;
          }),
          child: const Text('选择其他服务器'),
        ),
        if (p.fingerprint != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.verified_user_rounded, size: 16, color: Colors.green),
              const SizedBox(width: 6),
              Expanded(
                child: Text('证书已固定 ${p.fingerprint!.substring(0, 23)}…',
                    style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _banner(String msg) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(msg, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
        ]),
      );
}

class _Logo extends StatelessWidget {
  const _Logo({this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF4F7CFF), Color(0xFF7B5CFF)]),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(Icons.swap_horiz_rounded, color: Colors.white, size: size * 0.6),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    Widget point(IconData icon, String title, String sub) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: Colors.white70, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4)),
              ]),
            ),
          ]),
        );
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B3A8C), Color(0xFF4F3CB8)],
        ),
      ),
      padding: const EdgeInsets.all(40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Logo(),
        const SizedBox(height: 20),
        const Text('FileSwitch', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('你的设备之间的私有文件交换站', style: TextStyle(color: Colors.white70, fontSize: 15)),
        const Spacer(),
        point(Icons.lock_rounded, 'TLS 1.3 + 证书指纹固定', '所有流量加密，首次信任后锁定服务器证书，防止中间人攻击'),
        point(Icons.enhanced_encryption_rounded, '服务端静态加密', '文件在 NAS 磁盘上以 AES-256-GCM 加密，每个文件独立密钥'),
        point(Icons.devices_rounded, '设备级授权', '每台设备单独令牌，可随时一键撤销；密码使用 Argon2id 保护'),
        point(Icons.shield_rounded, '不暴露 SMB', '只开放一个 HTTPS 端口，无局域网广播，登录失败自动限流'),
        const Spacer(),
        const Text('v1.0', style: TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    );
  }
}
