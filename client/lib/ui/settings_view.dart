import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/transfers.dart';
import '../platform/shell.dart';
import 'dialogs.dart';
import 'format.dart';
import 'home_screen.dart' show ConnectionBadge;

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final s = AppState.instance;
  List<Device>? devices;
  String currentDevice = '';
  List<User>? users;
  List<AuditEntry>? audit;
  Stats? stats;
  bool? launchAtLogin;
  String downloadDir = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = s.api;
    if (api == null) return;
    try {
      final (d, cur) = await api.devices();
      final st = await api.stats();
      // password, audit log and user management are LAN-only
      final au = api.isRemote ? null : await api.audit();
      List<User>? us;
      if ((s.user?.isAdmin ?? false) && !api.isRemote) us = await api.users();
      final dl = await TransferManager.instance.defaultDownloadDir();
      final lal = isDesktop ? await Shell.instance.launchAtLogin() : null;
      if (!mounted) return;
      setState(() {
        devices = d;
        currentDevice = cur;
        stats = st;
        audit = au;
        users = us;
        downloadDir = dl;
        launchAtLogin = lal;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _changePassword() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final new2Ctrl = TextEditingController();
    var others = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: const Text('修改密码'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: oldCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
                TextField(
                  controller: newCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                ),
                TextField(
                  controller: new2Ctrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '再次输入新密码'),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: others,
                  onChanged: (v) => setState(() => others = v ?? true),
                  title: const Text('同时退出其他所有设备'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('修改')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (newCtrl.text != new2Ctrl.text) {
      toast(context, '两次输入的新密码不一致');
      return;
    }
    try {
      await s.api!.changePassword(oldCtrl.text, newCtrl.text, signOutOthers: others);
      if (mounted) toast(context, '密码已修改');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addDevice() async {
    final api = s.api!;
    if (api.isRemote && !(s.relay?.canPair ?? false)) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('添加新设备'),
          content: const Text(
            '为安全起见，NAS 设置为不允许经中转站添加设备（防止丢失的设备再"复制"出新设备）。\n\n'
            '请在家里的局域网内操作，或在 NAS 上执行：\ndocker exec fileswitch fileswitch pair <用户名>',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
        ),
      );
      return;
    }
    if (api.isRemote) toast(context, '正在请求 NAS 生成配对码（最长约一个同步周期）…');
    try {
      final (code, expires) = await api.createPairingCode();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('添加新设备'),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(10),
                  // fixed size: AlertDialog measures intrinsic sizes, which QrImageView can't report
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: QrImageView(data: code, size: 220, backgroundColor: Colors.white),
                ),
                ),
                const SizedBox(height: 12),
                const Text('用新手机的相机扫描二维码，或把下面的配对码复制到新设备的「使用配对码」中。'),
                const SizedBox(height: 8),
                SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                const SizedBox(height: 8),
                Text(
                  '${two(expires.hour)}:${two(expires.minute)} 前有效，只能使用一次。配对码相当于一次性钥匙，请勿发给他人。',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              child: const Text('复制配对码'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成')),
          ],
        ),
      );
      // The code is a one-time key; don't leave it in the clipboard (or in
      // clipboard history and sync) once the dialog is closed.
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (clip?.text == code) await Clipboard.setData(const ClipboardData(text: ''));
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _revoke(Device d) async {
    final self = d.id == currentDevice;
    final ok = await confirm(
      context,
      '撤销设备授权',
      self ? '这会让本机退出登录。' : '「${d.name}」将立即失去访问权限，需要重新输入密码登录。',
      ok: '撤销',
      danger: true,
    );
    if (!ok) return;
    try {
      if (self) {
        await s.signOut();
        return;
      }
      await s.api!.revokeDevice(d.id);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _renameDevice(Device d) async {
    final name = await textInput(context, '重命名设备', initial: d.name);
    if (name == null || name.isEmpty) return;
    try {
      await s.api!.renameDevice(d.id, name);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addUser() async {
    final name = TextEditingController();
    final pw = TextEditingController();
    var admin = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: const Text('添加用户'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '用户名（字母、数字、_ - .）'),
                ),
                TextField(
                  controller: pw,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '初始密码（至少 8 位）'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: admin,
                  onChanged: (v) => setState(() => admin = v ?? false),
                  title: const Text('管理员'),
                ),
                const Text('每个用户拥有独立、互相隔离的交换空间。', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await s.api!.createUser(name.text.trim(), pw.text, admin);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _userMenu(User u, String action) async {
    try {
      if (action == 'reset') {
        final pw = await textInput(context, '重置「${u.username}」的密码', label: '新密码（至少 8 位）', obscure: true);
        if (pw == null || pw.isEmpty) return;
        await s.api!.resetPassword(u.id, pw);
        if (mounted) toast(context, '已重置，该用户的所有设备已退出登录');
      } else if (action == 'delete') {
        final ok = await confirm(context, '删除用户「${u.username}」', '该用户的所有文件将被永久删除，无法恢复。', ok: '删除', danger: true);
        if (!ok) return;
        await s.api!.deleteUser(u.id);
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _section(String title, List<Widget> children, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final p = s.profile;
        final info = s.info;
        final cs = Theme.of(context).colorScheme;
        final content = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('当前连接', [
              ListTile(
                leading: Icon(Icons.dns_rounded, color: s.online ? Colors.green : cs.error),
                title: Text(info?.name ?? p?.name ?? ''),
                subtitle: Text(
                  '${(p?.url.isNotEmpty ?? false) ? p!.url : (p?.relayUrl ?? '')}\n${s.online ? '已连接' : '离线，正在重试…'} · 用户 ${s.user?.username ?? p?.username ?? ''}'
                  '${info == null ? '' : ' · 服务端 v${info.version}'}',
                ),
                isThreeLine: true,
              ),
              ListTile(
                leading: Icon(s.viaRelay ? Icons.cloud_sync_rounded : Icons.lan_rounded),
                title: const ConnectionBadge(),
                subtitle: Text(
                  s.viaRelay
                      ? '经公网中转站 ${s.relay?.creds.url ?? ''}\n文件内容、文件名、目录和分类都在本机加密后才发出，中转站只能看到密文；NAS 自己按计划从中转站取件，不对公网开放任何端口。'
                      : (p?.relayUrl.isNotEmpty ?? false)
                      ? '在家时直连 NAS；离开家后自动改走中转站 ${p!.relayUrl}'
                      : (info?.relayUrl.isNotEmpty ?? false)
                      ? '该 NAS 已配置中转站，正在为本机开通…'
                      : '该 NAS 未配置中转站，只能在局域网内使用',
                ),
                isThreeLine: true,
              ),
              if (!s.viaRelay)
                ListTile(
                  leading: const Icon(Icons.lock_rounded, color: Colors.green),
                  title: Text(p?.url.startsWith('https') ?? false ? 'TLS 1.3 加密传输' : '未加密的 HTTP 连接'),
                  subtitle: Text(
                    p?.fingerprint == null ? '证书由系统信任的机构签发' : '已固定服务器证书（防中间人）\nSHA-256 ${p!.fingerprint}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  isThreeLine: p?.fingerprint != null,
                ),
              ListTile(
                leading: Icon(
                  info?.encryptedAtRest ?? false ? Icons.enhanced_encryption_rounded : Icons.no_encryption_rounded,
                  color: info?.encryptedAtRest ?? false ? Colors.green : cs.outline,
                ),
                title: Text(info?.encryptedAtRest ?? false ? '服务端静态加密已开启' : '服务端静态加密未开启'),
                subtitle: const Text('文件在 NAS 磁盘上以 AES-256-GCM 加密存储，每个文件独立密钥'),
              ),
              if (stats != null)
                ListTile(
                  leading: const Icon(Icons.storage_rounded),
                  title: Text('${stats!.files} 个文件 · ${stats!.folders} 个文件夹 · ${formatBytes(stats!.bytes)}'),
                  subtitle: Text(
                    [
                      if (stats!.trashBytes > 0) '回收站 ${formatBytes(stats!.trashBytes)}',
                      if (stats!.diskTotal > 0)
                        'NAS 剩余 ${formatBytes(stats!.diskFree)} / ${formatBytes(stats!.diskTotal)}',
                    ].join(' · '),
                  ),
                ),
            ]),
            _section(
              '已授权的设备',
              trailing: TextButton.icon(
                onPressed: _addDevice,
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('添加新设备'),
              ),
              [
                if (devices == null) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
                for (final d in devices ?? const <Device>[])
                  ListTile(
                    key: ValueKey(d.id),
                    leading: Icon(platformIcon(d.platform)),
                    title: Row(
                      children: [
                        Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis)),
                        if (d.relay) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: d.remote ? '通过配对码加入，只能经中转站访问' : '可经中转站访问',
                            child: Icon(
                              d.remote ? Icons.cloud_rounded : Icons.cloud_sync_rounded,
                              size: 14,
                              color: cs.outline,
                            ),
                          ),
                        ],
                        if (d.id == currentDevice) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('本机', style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer)),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text('${platformLabel(d.platform)} · 最近活动 ${formatAgo(d.lastSeenAt)} · ${d.lastIp}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => v == 'rename' ? _renameDevice(d) : _revoke(d),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(
                          value: 'revoke',
                          child: Text('撤销授权', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (s.viaRelay)
              _section('账户安全', [
                const ListTile(
                  leading: Icon(Icons.shield_moon_rounded),
                  title: Text('修改密码、安全日志和用户管理只能在局域网直连时使用'),
                  subtitle: Text('这样即使中转站或某台外出的设备出了问题，也无法远程接管 NAS 账号'),
                ),
              ])
            else
              _section('账户安全', [
                ListTile(
                  leading: const Icon(Icons.password_rounded),
                  title: const Text('修改密码'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePassword,
                ),
                ExpansionTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('最近的安全事件'),
                  shape: const Border(),
                  children: [
                    for (final e in (audit ?? const <AuditEntry>[]).take(30))
                      ListTile(
                        dense: true,
                        leading: Icon(
                          e.action == 'login_failed' ? Icons.warning_amber_rounded : Icons.circle,
                          size: e.action == 'login_failed' ? 18 : 8,
                          color: e.action == 'login_failed' ? Colors.orange : cs.outline,
                        ),
                        title: Text('${auditLabel(e.action)}${e.detail.isEmpty ? '' : ' · ${e.detail}'}'),
                        subtitle: Text('${formatTime(e.at)} · ${e.ip}'),
                      ),
                  ],
                ),
              ]),
            if (users != null)
              _section(
                '用户管理',
                trailing: TextButton.icon(
                  onPressed: _addUser,
                  icon: const Icon(Icons.person_add_rounded),
                  label: const Text('添加'),
                ),
                [
                  for (final u in users!)
                    ListTile(
                      leading: Icon(u.isAdmin ? Icons.admin_panel_settings_rounded : Icons.person_rounded),
                      title: Text(u.username),
                      subtitle: Text('${u.isAdmin ? '管理员' : '普通用户'} · 创建于 ${formatTime(u.createdAt)}'),
                      trailing: u.id == s.user?.id
                          ? null
                          : PopupMenuButton<String>(
                              onSelected: (v) => _userMenu(u, v),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'reset', child: Text('重置密码')),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除用户', style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                    ),
                ],
              ),
            _section('本机设置', [
              if (isDesktop)
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('下载位置'),
                  subtitle: Text(downloadDir),
                  trailing: TextButton(
                    onPressed: () async {
                      final d = await FilePicker.getDirectoryPath(dialogTitle: '选择下载位置');
                      if (d == null) return;
                      s.config.downloadDir = d;
                      await s.saveConfig();
                      setState(() => downloadDir = d);
                    },
                    child: const Text('更改'),
                  ),
                ),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_rounded),
                title: const Text('其他设备投递新文件时通知我'),
                value: s.config.notifyIncoming,
                onChanged: (v) async {
                  s.config.notifyIncoming = v;
                  await s.saveConfig();
                  setState(() {});
                },
              ),
              if (isDesktop && launchAtLogin != null)
                SwitchListTile(
                  secondary: const Icon(Icons.power_settings_new_rounded),
                  title: const Text('开机自动启动'),
                  value: launchAtLogin!,
                  onChanged: (v) async {
                    try {
                      final ok = await Shell.instance.setLaunchAtLogin(v);
                      setState(() => launchAtLogin = ok ? v : launchAtLogin);
                      if (!ok && context.mounted) toast(context, '设置失败');
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
              if (isDesktop)
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_rounded),
                  title: const Text('启动时只显示托盘图标'),
                  value: s.config.startHidden,
                  onChanged: (v) async {
                    s.config.startHidden = v;
                    await s.saveConfig();
                    setState(() {});
                  },
                ),
            ]),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => s.detach(),
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('切换服务器'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                  onPressed: () async {
                    if (await confirm(context, '退出登录', '本机的授权将被撤销，下次需要重新输入密码。', ok: '退出登录')) {
                      await s.signOut();
                    }
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('退出登录'),
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        );
        if (MediaQuery.sizeOf(context).width < 700) {
          return Scaffold(
            appBar: AppBar(title: const Text('我的')),
            body: RefreshIndicator(onRefresh: _load, child: content),
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
              child: Row(
                children: [
                  Text('设备与安全', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: content),
              ),
            ),
          ],
        );
      },
    );
  }
}
