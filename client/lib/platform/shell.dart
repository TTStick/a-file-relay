import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import '../core/transfers.dart';

/// Desktop integration: window lifecycle, tray icon, the native macOS
/// drop panel, notifications and launch-at-login.
class Shell with WindowListener, TrayListener {
  Shell._();
  static final Shell instance = Shell._();

  static const _mac = MethodChannel('fileswitch/macos');

  /// UI hook: jump to the transfers page.
  void Function()? onShowTransfers;

  /// Windows: compact always-on-top drop panel instead of the full window.
  final miniMode = ValueNotifier<bool>(false);
  Rect? _savedBounds;

  String _lastState = '';
  String _lastProgress = '';

  Future<void> init({bool startHidden = false}) async {
    if (!isDesktop) return;
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(880, 560),
      center: true,
      title: 'FileSwitch',
    );
    windowManager.waitUntilReadyToShow(opts, () async {
      if (startHidden) {
        if (Platform.isMacOS) _mac.invokeMethod('setDockVisible', false);
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    if (Platform.isMacOS) {
      _mac.setMethodCallHandler(_onMacCall);
    } else {
      await _initTray();
    }
    AppState.instance.addListener(_syncState);
    TransferManager.instance.addListener(_syncProgress);
    AppState.instance.onIncoming = notify;
    _syncState();
  }

  // --- window ---

  Future<void> showMain() async {
    if (!isDesktop) return;
    if (miniMode.value) await setMiniMode(false);
    if (Platform.isMacOS) await _mac.invokeMethod('setDockVisible', true);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideMain() async {
    await windowManager.hide();
    if (Platform.isMacOS) await _mac.invokeMethod('setDockVisible', false);
  }

  Future<void> quit() async {
    await windowManager.setPreventClose(false);
    if (Platform.isWindows) await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) {
      if (miniMode.value) {
        await setMiniMode(false);
      }
      await hideMain();
    }
  }

  /// Windows: shrink the window into a small drop panel above the tray.
  Future<void> setMiniMode(bool on) async {
    if (on == miniMode.value) return;
    if (on) {
      _savedBounds = await windowManager.getBounds();
      miniMode.value = true;
      await windowManager.setMinimumSize(const Size(300, 260));
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      const size = Size(340, 440);
      final d = await screenRetriever.getPrimaryDisplay();
      final vp = d.visiblePosition ?? Offset.zero;
      final vs = d.visibleSize ?? d.size;
      await windowManager.setBounds(
          Rect.fromLTWH(vp.dx + vs.width - size.width - 12, vp.dy + vs.height - size.height - 12, size.width, size.height));
      await windowManager.show();
      await windowManager.focus();
    } else {
      miniMode.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(const Size(880, 560));
      if (_savedBounds != null) await windowManager.setBounds(_savedBounds!);
    }
  }

  // --- tray (Windows) ---

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray/tray_icon.ico');
    await trayManager.setToolTip('FileSwitch');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: '打开 FileSwitch'),
      MenuItem(key: 'mini', label: '迷你投递窗'),
      MenuItem(key: 'transfers', label: '传输列表'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
    trayManager.addListener(this);
  }

  @override
  void onTrayIconMouseDown() => showMain();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        showMain();
      case 'mini':
        setMiniMode(true);
      case 'transfers':
        showMain().then((_) => onShowTransfers?.call());
      case 'quit':
        quit();
    }
  }

  // --- macOS native side ---

  Future<dynamic> _onMacCall(MethodCall call) async {
    switch (call.method) {
      case 'drop':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final paths = (args['paths'] as List).cast<String>();
        final catId = (args['categoryId'] as String?) ?? '';
        final cat = AppState.instance.categoryById(catId);
        if (!AppState.instance.signedIn) {
          await showMain();
          return false;
        }
        TransferManager.instance.upload(paths,
            categoryId: catId.isEmpty ? null : catId, destination: cat?.name ?? '全部文件');
        return true;
      case 'showMain':
        await showMain();
      case 'showTransfers':
        await showMain();
        onShowTransfers?.call();
      case 'quit':
        await quit();
    }
    return null;
  }

  void _syncState() {
    if (!isDesktop) return;
    final s = AppState.instance;
    final state = {
      'signedIn': s.signedIn,
      'online': s.online,
      'server': s.info?.name ?? s.profile?.name ?? '',
      'categories': s.categories.map((c) => c.toPanelJson()).toList(),
    };
    final key = jsonEncode(state);
    if (key == _lastState) return;
    _lastState = key;
    if (Platform.isMacOS) {
      _mac.invokeMethod('setState', state);
    } else if (Platform.isWindows) {
      trayManager.setToolTip(s.signedIn ? 'FileSwitch · ${state['server']}${s.online ? '' : '（离线）'}' : 'FileSwitch · 未登录');
    }
  }

  void _syncProgress() {
    final t = TransferManager.instance;
    final pr = t.uploadProgress;
    final active = t.items.where((x) => x.active && x.kind == TransferKind.upload).length;
    final key = '$active:${pr == null ? -1 : (pr * 100).floor()}';
    if (key == _lastProgress) return;
    _lastProgress = key;
    if (Platform.isMacOS) {
      _mac.invokeMethod('setProgress', {'active': active, 'progress': pr ?? -1.0});
    } else if (Platform.isWindows) {
      trayManager.setToolTip(active > 0 ? 'FileSwitch · 正在上传 $active 项 ${((pr ?? 0) * 100).floor()}%' : 'FileSwitch');
    }
  }

  // --- notifications ---

  void notify(String title, String body) {
    try {
      if (Platform.isMacOS) {
        _mac.invokeMethod('notify', {'title': title, 'body': body});
      } else if (Platform.isWindows) {
        // A WinRT toast via PowerShell avoids a native plugin. Text goes through
        // the environment so nothing needs shell escaping.
        Process.run('powershell', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', _toastScript],
            environment: {'FS_TITLE': title, 'FS_BODY': body});
      }
    } catch (_) {}
  }

  static const _toastScript = r'''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$t = [Security.SecurityElement]::Escape($env:FS_TITLE)
$b = [Security.SecurityElement]::Escape($env:FS_BODY)
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($x))
''';

  // --- launch at login ---

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  Future<bool> launchAtLogin() async {
    try {
      if (Platform.isMacOS) return (await _mac.invokeMethod<bool>('getLaunchAtLogin')) ?? false;
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', _runKey, '/v', 'FileSwitch']);
        return r.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  Future<bool> setLaunchAtLogin(bool on) async {
    if (Platform.isMacOS) return (await _mac.invokeMethod<bool>('setLaunchAtLogin', on)) ?? false;
    if (Platform.isWindows) {
      final r = on
          ? await Process.run('reg',
              ['add', _runKey, '/v', 'FileSwitch', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --hidden', '/f'])
          : await Process.run('reg', ['delete', _runKey, '/v', 'FileSwitch', '/f']);
      return r.exitCode == 0;
    }
    return false;
  }

  // --- local files ---

  /// Opens a local file with its default app (desktop) or the share sheet (mobile).
  Future<void> openLocal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['--', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    } else {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    }
  }

  Future<void> revealLocal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', '--', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    }
  }

  String get revealLabel => Platform.isMacOS
      ? '在 Finder 中显示'
      : Platform.isWindows
          ? '在资源管理器中显示'
          : '分享';
}
