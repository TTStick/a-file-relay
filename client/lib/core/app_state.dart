import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'api.dart';
import 'backend.dart';
import 'models.dart';
import 'relay_backend.dart';
import 'storage.dart';

String platformName() => Platform.operatingSystem;

bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

String defaultDeviceName() {
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android 设备';
  var h = Platform.localHostname;
  if (h.endsWith('.local')) h = h.substring(0, h.length - 6);
  return h.isEmpty ? (Platform.isMacOS ? 'Mac' : 'Windows 电脑') : h;
}

/// Session and server-wide state: which NAS we're signed in to, whether we
/// reach it directly on the LAN or through the relay, the account,
/// categories, and the live event stream.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  AppConfig config = AppConfig();
  bool ready = false;
  ServerProfile? profile;
  Backend? api;
  User? user;
  Device? device;
  ServerInfo? info;
  List<Category> categories = [];
  bool online = false;

  /// Shown on the sign-in screen after the session ended on its own.
  String? sessionMessage;

  /// A fileswitch://pair link the app was opened with, for the connect screen.
  String? pendingPairCode;

  void openPairLink(Uri uri) {
    if (uri.scheme != 'fileswitch' || uri.host != 'pair') return;
    if (signedIn) {
      _notices.add('收到配对链接。若要用它连接另一个交换站，请先在侧边栏「切换服务器」后再打开链接');
      return;
    }
    pendingPairCode = uri.toString();
    notifyListeners();
  }

  /// Desktop shell hook for "new files from another device" notifications.
  void Function(String title, String body)? onIncoming;

  final _events = StreamController<ServerEvent>.broadcast();
  Stream<ServerEvent> get events => _events.stream;

  /// Messages for a snackbar (e.g. an operation the NAS rejected later).
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  StreamSubscription<ServerEvent>? _sse;
  StreamSubscription<ServerEvent>? _localSub;
  Timer? _reconnect;
  Timer? _modeTimer;
  int _retryDelay = 1;
  int _generation = 0;

  final _incoming = <String, List<String>>{};
  Timer? _incomingTimer;

  bool get signedIn => api != null;
  bool get viaRelay => api?.isRemote ?? false;
  RelayBackend? get relay => api is RelayBackend ? api as RelayBackend : null;

  Category? categoryById(String id) => categories.where((c) => c.id == id).firstOrNull;

  /// The category shown for a node: its own tag, or the category whose drop
  /// folder it is.
  Category? categoryOf(Node n) =>
      categoryById(n.categoryId) ?? (n.isDir ? categories.where((c) => c.folderId == n.id).firstOrNull : null);

  ServerProfile? profileById(String id) => config.profiles.where((e) => e.id == id).firstOrNull;

  Future<void> loadConfig() async {
    config = await Storage.load();
  }

  /// Restores the last session. The UI shows immediately (offline until the
  /// server answers) rather than waiting on the network.
  Future<void> init() async {
    final id = config.activeId;
    final p = id == null ? null : profileById(id);
    if (p != null && await hasToken(p)) unawaited(_activate(p));
    ready = true;
    notifyListeners();
  }

  Future<void> saveConfig() => Storage.save(config);

  Future<void> upsertProfile(ServerProfile p) async {
    final i = config.profiles.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      config.profiles[i] = p;
    } else {
      config.profiles.add(p);
    }
    await saveConfig();
    notifyListeners();
  }

  Future<void> removeProfile(ServerProfile p) async {
    if (profile?.id == p.id) await signOut();
    config.profiles.removeWhere((e) => e.id == p.id);
    await Storage.setToken(p.id, null);
    await Storage.setRelay(p.id, null);
    await saveConfig();
    notifyListeners();
  }

  Future<bool> hasToken(ServerProfile p) async =>
      (await Storage.token(p.id)) != null || (await Storage.relay(p.id)) != null;

  /// Switches to a profile that still has stored credentials.
  Future<void> resume(ServerProfile p) async {
    if (!await hasToken(p)) throw ApiException(401, 'unauthorized', '请重新登录');
    config.activeId = p.id;
    p.lastUsed = DateTime.now();
    await saveConfig();
    await _activate(p);
  }

  Future<void> login(ServerProfile p, String username, String password, String deviceName) async {
    final c = ApiClient(base: Uri.parse(p.url), fingerprint: p.fingerprint);
    try {
      final (token, _, _) = await c.login(username, password, deviceName, platformName());
      p
        ..username = username
        ..deviceName = deviceName
        ..lastUsed = DateTime.now();
      await Storage.setToken(p.id, token);
      config.activeId = p.id;
      await upsertProfile(p);
      sessionMessage = null;
      await _activate(p);
    } finally {
      c.close();
    }
  }

  /// Adds this device through the relay with a code made on the NAS (or on
  /// another enrolled device). No LAN access needed.
  Future<void> pairWithCode(String code, String deviceName, {void Function(String)? onStatus}) async {
    final creds = await RelayBackend.pair(code, deviceName, platformName(), onStatus: onStatus);
    final existing = config.profiles.where((p) => p.relayUrl == creds.url && p.username == creds.username).firstOrNull;
    final p = existing ??
        ServerProfile(
            id: List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
            url: '',
            name: creds.serverName);
    p
      ..relayUrl = creds.url
      ..username = creds.username
      ..deviceName = deviceName
      ..lastUsed = DateTime.now();
    await Storage.setRelay(p.id, creds.json);
    config.activeId = p.id;
    await upsertProfile(p);
    sessionMessage = null;
    await _activate(p);
  }

  RelayBackend _relayBackend(ServerProfile p, RelayCreds creds) =>
      RelayBackend(creds, onCredsChanged: (c) => Storage.setRelay(p.id, c.json));

  /// Picks how to reach the NAS: directly when it answers on the LAN, else
  /// through the relay if this device is enrolled.
  Future<Backend?> _chooseBackend(ServerProfile p) async {
    final token = await Storage.token(p.id);
    final relayJson = await Storage.relay(p.id);
    final creds = relayJson == null ? null : RelayCreds(relayJson);
    if (token != null && p.url.isNotEmpty) {
      final direct = ApiClient(base: Uri.parse(p.url), fingerprint: p.fingerprint, token: token);
      if (creds == null) return direct; // LAN-only device: keep retrying the LAN
      try {
        await direct.info().timeout(const Duration(seconds: 3));
        return direct;
      } catch (_) {}
      direct.close();
    }
    return creds == null ? null : _relayBackend(p, creds);
  }

  Future<void> _activate(ServerProfile p, {Backend? backend}) async {
    final b = backend ?? await _chooseBackend(p);
    if (b == null) {
      await _sessionLost('请重新登录');
      return;
    }
    _stopEvents();
    _localSub?.cancel();
    final old = api;
    if (old is RelayBackend) old.removeListener(notifyListeners);
    old?.close();
    final gen = ++_generation;
    profile = p;
    api = b;
    online = false;
    if (b is RelayBackend) {
      b.addListener(notifyListeners);
      _localSub = b.localEvents.listen((ev) {
        if (ev.type == 'op.failed') {
          _notices.add('NAS 未能执行操作：${ev.target}');
        } else {
          _events.add(ev);
        }
      });
    }
    notifyListeners();
    await refreshSession(gen);
    if (gen == _generation && api != null) {
      _startEvents(gen);
      _scheduleModeCheck();
      if (b is ApiClient) unawaited(_ensureRelayEnrollment(p, b));
    }
  }

  /// On the LAN: if the NAS has a relay, get relay credentials so this device
  /// keeps working away from home.
  Future<void> _ensureRelayEnrollment(ServerProfile p, ApiClient direct) async {
    final relayUrl = info?.relayUrl ?? '';
    if (relayUrl.isEmpty || await Storage.relay(p.id) != null) return;
    try {
      final bundle = await direct.enrollRelay();
      await Storage.setRelay(p.id, bundle);
      p.relayUrl = RelayCreds(bundle).url;
      await upsertProfile(p);
      _notices.add('此设备已开通中转访问：离开家里的网络也能使用');
    } catch (_) {}
  }

  /// While on the relay, check now and then whether the NAS answers directly
  /// again (back home) and switch to the faster LAN connection.
  void _scheduleModeCheck() {
    _modeTimer?.cancel();
    _modeTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      final p = profile;
      if (p == null || api == null || !api!.isRemote || p.url.isEmpty) return;
      final b = await _chooseBackend(p);
      if (b is ApiClient && profile?.id == p.id && (api?.isRemote ?? false)) {
        await _activate(p, backend: b);
      } else {
        b?.close();
      }
    });
  }

  Future<void> refreshSession([int? gen]) async {
    final a = api;
    if (a == null) return;
    try {
      final (u, d) = await a.me();
      if (gen != null && gen != _generation) return;
      user = u;
      device = d;
      online = true;
      info = await a.info();
      await refreshCategories();
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await _sessionLost(a.isRemote ? '此设备的中转授权已被撤销' : '登录已失效，请重新登录');
        return;
      }
      online = false;
    }
    notifyListeners();
  }

  Future<void> refreshCategories() async {
    final a = api;
    if (a == null) return;
    try {
      categories = await a.categories();
      notifyListeners();
    } on ApiException catch (e) {
      if (e.unauthorized) await _sessionLost('登录已失效，请重新登录');
    }
  }

  void _startEvents(int gen) {
    _reconnect?.cancel();
    final a = api;
    if (a == null) return;
    _sse = a.events().listen(
      (ev) {
        if (gen != _generation) return;
        _retryDelay = 1;
        if (ev.type == 'hello') {
          if (!online) {
            online = true;
            refreshSession();
          } else if (a.isRemote) {
            refreshCategories();
          }
        }
        _handle(ev);
      },
      onError: (Object e) {
        if (gen != _generation) return;
        if (e is ApiException && e.unauthorized) {
          _sessionLost(a.isRemote ? '此设备的中转授权已被撤销' : '登录已失效，请重新登录');
          return;
        }
        _scheduleReconnect(gen);
      },
      onDone: () {
        if (gen == _generation) _scheduleReconnect(gen);
      },
      cancelOnError: true,
    );
  }

  void _scheduleReconnect(int gen) {
    _sse = null;
    if (online) {
      online = false;
      notifyListeners();
    }
    _reconnect?.cancel();
    final delay = _retryDelay;
    _reconnect = Timer(Duration(seconds: delay), () async {
      if (gen != _generation) return;
      // Lost the LAN (left home)? Continue through the relay if enrolled.
      final p = profile;
      if (p != null && api is ApiClient && delay >= 2) {
        final b = await _chooseBackend(p);
        if (gen != _generation) {
          b?.close();
          return;
        }
        if (b is RelayBackend) {
          await _activate(p, backend: b);
          return;
        }
        b?.close();
      }
      _startEvents(gen);
    });
    _retryDelay = min(_retryDelay * 2, 30);
  }

  void _stopEvents() {
    _reconnect?.cancel();
    // Closing the client aborts the stream; that error surfaces through the
    // cancel future, and it's expected.
    _sse?.cancel().ignore();
    _sse = null;
  }

  /// Reconnect right away (e.g. when the app comes back to the foreground).
  void reconnectNow() {
    if (api == null || _sse != null) return;
    _retryDelay = 1;
    _startEvents(_generation);
  }

  void _handle(ServerEvent ev) {
    switch (ev.type) {
      case 'device.revoked':
        if (ev.target == device?.id) {
          _sessionLost('此设备的授权已被撤销');
          return;
        }
      case 'category.changed':
        refreshCategories();
      case 'node.created':
        final n = ev.node;
        if (n != null && n.timeline && ev.deviceId != device?.id && config.notifyIncoming) {
          (_incoming[n.deviceName.isEmpty ? '其他设备' : n.deviceName] ??= []).add(n.name);
          _incomingTimer ??= Timer(const Duration(milliseconds: 1500), _flushIncoming);
        }
    }
    _events.add(ev);
  }

  void _flushIncoming() {
    _incomingTimer = null;
    _incoming.forEach((dev, names) {
      final body = names.length == 1 ? names.first : '${names.first} 等 ${names.length} 项';
      onIncoming?.call('来自 $dev 的新文件', body);
    });
    _incoming.clear();
  }

  Future<void> _sessionLost(String message) async {
    final p = profile;
    if (p != null) {
      await Storage.setToken(p.id, null);
      await Storage.setRelay(p.id, null);
    }
    _clear();
    sessionMessage = message;
    notifyListeners();
  }

  void _clear() {
    _generation++;
    _stopEvents();
    _modeTimer?.cancel();
    _localSub?.cancel();
    final a = api;
    if (a is RelayBackend) a.removeListener(notifyListeners);
    a?.close();
    api = null;
    user = null;
    device = null;
    info = null;
    categories = [];
    online = false;
  }

  Future<void> signOut() async {
    final a = api;
    final p = profile;
    if (a != null) {
      try {
        await a.logout();
      } catch (_) {}
    }
    if (p != null) {
      await Storage.setToken(p.id, null);
      await Storage.setRelay(p.id, null);
    }
    config.activeId = null;
    await saveConfig();
    _clear();
    notifyListeners();
  }

  /// Leaves the current server without revoking its credentials (to switch servers).
  Future<void> detach() async {
    config.activeId = null;
    await saveConfig();
    _clear();
    notifyListeners();
  }
}
