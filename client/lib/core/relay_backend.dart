import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'api.dart';
import 'backend.dart';
import 'e2e.dart';
import 'models.dart';

/// Credentials of a device enrolled for relay access (kept in the keychain).
/// Stored in the same shape as the NAS's enrollment bundle.
class RelayCreds {
  RelayCreds(this.json);
  final Map<String, dynamic> json;

  String get url => ((json['relay'] as Map)['url'] as String).replaceAll(RegExp(r'/+$'), '');
  String? get fingerprint => (json['relay'] as Map)['fingerprint'] as String?;
  String get spaceId => json['space_id'] as String;
  String get deviceId => json['device_id'] as String;
  Uint8List get deviceKey => base64.decode(json['device_key'] as String);
  String get token => json['relay_token'] as String;
  String get serverName => (json['server_name'] as String?) ?? 'FileSwitch';
  String get username => ((json['user'] as Map?)?['username'] as String?) ?? '';
  Keyring get keyring => keyringFromJson(json['keyring'] as Map);
  int get current => ((json['keyring'] as Map)['current'] as num).toInt();

  void setKeyring(Map<String, dynamic> k) => json['keyring'] = k;
}

HttpClient _pinnedClient(String? fingerprint) => pinnedHttpClient(fingerprint)
  ..connectionTimeout = const Duration(seconds: 15)
  ..idleTimeout = const Duration(seconds: 30)
  ..maxConnectionsPerHost = 6
  ..userAgent = 'FileSwitch/1.0';

ApiException _wrapNet(Object e) {
  if (e is ApiException) return e;
  if (e is CanceledException) throw e;
  if (e is HandshakeException || e is TlsException) return ApiException(0, 'tls', '与中转站的安全连接失败（证书不匹配？）');
  if (e is TimeoutException) return ApiException(0, 'timeout', '中转站响应超时');
  return ApiException(0, 'network', '无法连接中转站');
}

/// The metadata the NAS publishes (decrypted), with indexes for browsing.
class Snapshot {
  Snapshot(this.version, Map<String, dynamic> j)
      : kid = (j['kid'] as num).toInt(),
        server = ((j['server'] as Map?) ?? {}).cast<String, dynamic>(),
        policy = ((j['policy'] as Map?) ?? {}).cast<String, dynamic>(),
        user = User.fromJson((j['user'] as Map).cast<String, dynamic>()),
        nodes = _list(j['nodes']).map(Node.fromJson).toList(),
        trash = _list(j['trash']).map(Node.fromJson).toList(),
        categories = _list(j['categories']).map(Category.fromJson).toList(),
        devices = _list(j['devices']).map(Device.fromJson).toList(),
        _stats = ((j['stats'] as Map?) ?? {}).cast<String, dynamic>() {
    reindex();
  }

  static List<Map<String, dynamic>> _list(dynamic v) =>
      ((v as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  final int version;
  final int kid;
  final Map<String, dynamic> server;
  final Map<String, dynamic> policy;
  final User user;
  List<Node> nodes;
  List<Node> trash;
  List<Category> categories;
  List<Device> devices;
  final Map<String, dynamic> _stats;

  late Map<String, Node> byId;
  late Map<String, List<Node>> kids;

  void reindex() {
    byId = {for (final n in nodes) n.id: n};
    kids = {};
    for (final n in nodes) {
      if (n.parentId.isNotEmpty) (kids[n.parentId] ??= []).add(n);
    }
  }

  Stats get stats {
    int n(String k) => (_stats[k] as num?)?.toInt() ?? 0;
    return Stats(n('files'), n('folders'), n('bytes'), n('trash_bytes'), 0, 0);
  }

  List<Crumb> path(String id) {
    final out = <Crumb>[];
    var cur = byId[id];
    var guard = 0;
    while (cur != null && guard++ < 128) {
      out.insert(0, Crumb(cur.id, cur.name));
      cur = cur.parentId.isEmpty ? null : byId[cur.parentId];
    }
    return out;
  }

  String location(Node n) {
    if (n.parentId.isEmpty) return '';
    final p = path(n.parentId);
    return '/${p.skip(1).map((c) => c.name).join('/')}';
  }

  Node located(Node n) => n.withLocation(location(n));

  Node? removeSubtree(String id) {
    final n = byId[id];
    if (n == null) return null;
    final gone = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final x in nodes) {
        if (!gone.contains(x.id) && gone.contains(x.parentId)) {
          gone.add(x.id);
          grew = true;
        }
      }
    }
    nodes = nodes.where((x) => !gone.contains(x.id)).toList();
    reindex();
    return n;
  }

  void replace(Node n) {
    nodes = [for (final x in nodes) x.id == n.id ? n : x];
    reindex();
  }
}

/// Talks to the NAS through the relay. Reads come from the encrypted snapshot
/// the NAS publishes; changes are sealed operations the NAS applies on its
/// next sync, shown optimistically until it confirms.
class RelayBackend with ChangeNotifier implements Backend {
  RelayBackend(this.creds, {required this.onCredsChanged}) : _http = _pinnedClient(creds.fingerprint);

  final RelayCreds creds;
  final Future<void> Function(RelayCreds) onCredsChanged;
  final HttpClient _http;

  Snapshot? _snap;
  Future<Snapshot>? _loading;
  int _replySeq = -1;
  final _waiters = <String, Completer<Map<String, dynamic>>>{};
  final _optimistic = <String, void Function(Snapshot)>{};
  final _cacheWaiters = <String, Completer<void>>{};
  final _requested = <String, DateTime>{};
  final _local = StreamController<ServerEvent>.broadcast();
  Timer? _replyTimer;
  DateTime _lastStatus = DateTime(0);

  /// When the NAS last contacted the relay.
  DateTime? nasSeen;

  /// Operations sent but not yet confirmed by the NAS.
  int get pendingOps => _waiters.length;

  /// Optimistic refreshes and failures of operations, for the UI.
  Stream<ServerEvent> get localEvents => _local.stream;

  @override
  bool get isRemote => true;

  @override
  String get modeLabel => '经中转站';

  @override
  bool get canPurge => (_snap?.policy['remote_purge'] as bool?) ?? false;

  bool get canPair => (_snap?.policy['remote_pairing'] as bool?) ?? false;

  @override
  void close() {
    _replyTimer?.cancel();
    _http.close(force: true);
  }

  // --- HTTP ---

  Uri _uri(String path, [Map<String, String>? q]) {
    final b = Uri.parse(creds.url);
    return b.replace(path: '${b.path}$path', queryParameters: (q == null || q.isEmpty) ? null : q);
  }

  Future<HttpClientResponse> _send(String method, String path,
      {Object? json, List<int>? bytes, Map<String, String>? query, Map<String, String>? headers, CancelToken? cancel}) async {
    HttpClientRequest? req;
    void Function()? unhook;
    try {
      req = await _http.openUrl(method, _uri(path, query));
      final r = req;
      unhook = cancel?.onCancel(() => r.abort(CanceledException()));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${creds.token}');
      headers?.forEach(req.headers.set);
      if (json != null) {
        final b = utf8.encode(jsonEncode(json));
        req.headers.contentType = ContentType.json;
        req.contentLength = b.length;
        req.add(b);
      } else if (bytes != null) {
        req.headers.contentType = ContentType.binary;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      return await req.close().timeout(const Duration(minutes: 2));
    } catch (e) {
      cancel?.check();
      throw _wrapNet(e);
    } finally {
      unhook?.call();
    }
  }

  Future<dynamic> _call(String method, String path, {Object? json, Map<String, String>? query}) async {
    final resp = await _send(method, path, json: json, query: query);
    final text = await utf8.decodeStream(resp).timeout(const Duration(minutes: 1), onTimeout: () => throw _wrapNet(TimeoutException('')));
    if (resp.statusCode == 401) throw ApiException(401, 'unauthorized', '此设备的中转授权已失效');
    if (resp.statusCode >= 400) {
      String msg = '中转站错误 (${resp.statusCode})';
      try {
        msg = ((jsonDecode(text) as Map)['error'] as Map)['message'] as String;
      } catch (_) {}
      throw ApiException(resp.statusCode, 'relay', msg);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  // --- keys & snapshot ---

  Future<void> _refreshKeyring() async {
    final env = await _call('GET', '/r/v1/keyring') as Map;
    final p = await openEnvelope(creds.deviceKey, env, keyringAAD(creds.deviceId));
    creds.setKeyring((jsonDecode(utf8.decode(p)) as Map).cast<String, dynamic>());
    await onCredsChanged(creds);
  }

  Future<Snapshot> _ensure() {
    final s = _snap;
    if (s != null) return Future.value(s);
    return _loading ??= _fetchSnapshot().whenComplete(() => _loading = null).then((s) => s!);
  }

  /// Fetches the snapshot if it changed; returns it (or null if unchanged).
  Future<Snapshot?> _fetchSnapshot() async {
    final have = _snap?.version;
    final resp = await _send('GET', '/r/v1/snapshot', query: {if (have != null) 'have': '$have'});
    if (resp.statusCode == 304) {
      await resp.drain<void>();
      return null;
    }
    if (resp.statusCode == 404) {
      await resp.drain<void>();
      throw ApiException(0, 'no_snapshot', 'NAS 还没有把数据同步到中转站，请确认 NAS 在线');
    }
    if (resp.statusCode == 401) {
      await resp.drain<void>();
      throw ApiException(401, 'unauthorized', '此设备的中转授权已失效');
    }
    final b = BytesBuilder(copy: false);
    await for (final c in resp) {
      b.add(c);
    }
    final data = b.takeBytes();
    (int, Map<String, dynamic>) opened;
    try {
      opened = await openSnapshot(data, creds.spaceId, creds.keyring);
    } on E2EAuthError {
      await _refreshKeyring(); // the space key may have rotated
      opened = await openSnapshot(data, creds.spaceId, creds.keyring);
    }
    final snap = Snapshot(opened.$1, opened.$2);
    for (final f in _optimistic.values) {
      f(snap);
    }
    _snap = snap;
    notifyListeners();
    return snap;
  }

  /// Refreshes the snapshot and returns new timeline items from other devices.
  Future<List<Node>> _refreshSnapshot() async {
    final before = _snap;
    final fresh = await _fetchSnapshot();
    if (fresh == null || before == null) return const [];
    return fresh.nodes
        .where((n) => n.timeline && !before.byId.containsKey(n.id) && n.deviceId != creds.deviceId)
        .toList();
  }

  Future<void> _refreshStatus() async {
    _lastStatus = DateTime.now();
    final j = await _call('GET', '/r/v1/status') as Map;
    final seen = (j['nas_seen'] as num?)?.toInt() ?? 0;
    final now = (j['now'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    // express relative to our clock (the relay's may differ)
    nasSeen = seen == 0 ? null : DateTime.now().subtract(Duration(milliseconds: now - seen));
    notifyListeners();
  }

  // --- operations ---

  Future<Map<String, dynamic>> _op(Map<String, dynamic> op,
      {bool wait = false, Duration timeout = const Duration(minutes: 5), void Function(Snapshot)? optimistic}) async {
    final id = randomHex(16);
    op['ts'] = DateTime.now().millisecondsSinceEpoch;
    final env = await sealEnvelope(creds.deviceKey, utf8.encode(jsonEncode(op)), opAAD(creds.deviceId, id));
    final c = Completer<Map<String, dynamic>>();
    _waiters[id] = c;
    try {
      await _call('POST', '/r/v1/ops', json: {'id': id, ...env});
    } catch (e) {
      _waiters.remove(id);
      rethrow;
    }
    if (optimistic != null) {
      _optimistic[id] = optimistic;
      final s = _snap;
      if (s != null) optimistic(s);
      _local.add(ServerEvent('hello', null, '', '', '', ''));
    }
    notifyListeners();
    _replyTimer ??= Timer.periodic(const Duration(seconds: 10), (_) => _pullReplies().ignore());
    if (!wait) {
      c.future.then((_) {}, onError: (Object e) {
        _local.add(ServerEvent('op.failed', null, '', '', '', e.toString()));
        _snap = null; // drop the optimistic view
        _local.add(ServerEvent('hello', null, '', '', '', ''));
      });
      return const {};
    }
    return c.future.timeout(timeout,
        onTimeout: () => throw ApiException(0, 'nas_offline', 'NAS 暂未处理（可能离线），操作会在 NAS 上线后执行'));
  }

  Future<void> _pullReplies() async {
    if (_replySeq < 0 && _waiters.isEmpty) {
      // first contact: skip replies from earlier sessions
      final j = await _call('GET', '/r/v1/replies', query: {'after': '0'}) as Map;
      final list = (j['replies'] as List);
      _replySeq = list.isEmpty ? 0 : ((list.last as Map)['seq'] as num).toInt();
      return;
    }
    final j = await _call('GET', '/r/v1/replies', query: {'after': '${max(_replySeq, 0)}'}) as Map;
    for (final r in (j['replies'] as List).whereType<Map>()) {
      final seq = r['seq'], id = r['op'];
      if (seq is num) _replySeq = max(_replySeq, seq.toInt());
      if (id is! String) continue;
      final c = _waiters.remove(id);
      _optimistic.remove(id);
      if (c == null) continue;
      // Whatever is wrong with a reply, its waiter gets an answer now instead
      // of hanging until the timeout.
      try {
        final p = await openEnvelope(creds.deviceKey, r['body'] as Map, replyAAD(creds.deviceId, id));
        final reply = (jsonDecode(utf8.decode(p)) as Map).cast<String, dynamic>();
        if (reply['ok'] == true) {
          c.complete(((reply['data'] as Map?) ?? {}).cast<String, dynamic>());
        } else {
          c.completeError(ApiException(400, 'nas', (reply['error'] as String?) ?? 'NAS 拒绝了该操作'));
        }
      } catch (_) {
        c.completeError(ApiException(0, 'auth', '收到无法验证的回复，已忽略'));
      }
    }
    if (_waiters.isEmpty) {
      _replyTimer?.cancel();
      _replyTimer = null;
    }
    notifyListeners();
  }

  // --- events ---

  @override
  Stream<ServerEvent> events() async* {
    final resp = await _send('GET', '/r/v1/events', headers: {HttpHeaders.acceptHeader: 'text/event-stream'});
    if (resp.statusCode == 401) {
      await resp.drain<void>();
      throw ApiException(401, 'unauthorized', '此设备的中转授权已失效');
    }
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw ApiException(resp.statusCode, 'relay', '中转站错误');
    }
    final lines = resp.timeout(const Duration(seconds: 70)).cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    try {
      await for (final line in lines) {
        if (line.startsWith(':')) {
          if (DateTime.now().difference(_lastStatus) > const Duration(seconds: 60)) _refreshStatus().ignore();
          continue;
        }
        if (!line.startsWith('data: ')) continue;
        final j = jsonDecode(line.substring(6)) as Map;
        switch (j['type']) {
          case 'hello':
            await _refreshStatus();
            await _pullReplies();
            try {
              await _fetchSnapshot();
            } on ApiException catch (e) {
              if (e.code != 'no_snapshot') rethrow;
            }
            yield ServerEvent('hello', null, '', '', '', '');
          case 'snapshot':
            for (final n in await _refreshSnapshot()) {
              yield ServerEvent('node.created', n, n.parentId, '', n.deviceId, '');
            }
            yield ServerEvent('hello', null, '', '', '', '');
          case 'reply':
            await _pullReplies();
          case 'cache':
            _cacheWaiters.remove(j['key'])?.complete();
          case 'keyring':
            await _refreshKeyring();
        }
      }
    } catch (e) {
      throw _wrapNet(e);
    }
  }

  // --- reads ---

  @override
  Future<(User, Device)> me() async {
    final s = await _ensure();
    final d = s.devices.where((d) => d.id == creds.deviceId).firstOrNull ??
        Device(creds.deviceId, '本机', Platform.operatingSystem, DateTime.now(), DateTime.now(), '', relay: true);
    return (s.user, d);
  }

  @override
  Future<ServerInfo> info() async {
    final s = await _ensure();
    return ServerInfo((s.server['name'] as String?) ?? creds.serverName, (s.server['version'] as String?) ?? '',
        (s.server['encrypted_at_rest'] as bool?) ?? true, 8 << 20, 0,
        relayUrl: creds.url);
  }

  @override
  Future<Stats> stats() async => (await _ensure()).stats;

  @override
  Future<(List<Device>, String)> devices() async => ((await _ensure()).devices, creds.deviceId);

  @override
  Future<List<Category>> categories() async => List.of((await _ensure()).categories);

  @override
  Future<Listing> list(String? parentId, {bool dirsOnly = false}) async {
    final s = await _ensure();
    final pid = (parentId == null || parentId.isEmpty) ? s.user.rootId : parentId;
    final parent = s.byId[pid];
    if (parent == null) throw ApiException(404, 'not_found', '文件或对象不存在');
    final kids = [for (final n in s.kids[pid] ?? const <Node>[]) if (!dirsOnly || n.isDir) n]
      ..sort((a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Listing(parent, s.path(pid), kids);
  }

  @override
  Future<(Node, List<Crumb>)> node(String id) async {
    final s = await _ensure();
    final n = s.byId[id];
    if (n == null) throw ApiException(404, 'not_found', '文件或对象不存在');
    return (n, s.path(id));
  }

  @override
  Future<List<WalkEntry>> walk(String id) async {
    final s = await _ensure();
    final root = s.byId[id];
    if (root == null) throw ApiException(404, 'not_found', '文件或对象不存在');
    final out = <WalkEntry>[WalkEntry(root, root.name)];
    for (var i = 0; i < out.length; i++) {
      for (final c in s.kids[out[i].node.id] ?? const <Node>[]) {
        out.add(WalkEntry(c, '${out[i].relPath}/${c.name}'));
      }
    }
    return out;
  }

  (List<Node>, bool) _page(Snapshot s, Iterable<Node> items, DateTime? before, int limit) {
    final list = items.where((n) => before == null || n.createdAt.isBefore(before)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final page = list.take(limit).map(s.located).toList();
    return (page, list.length > limit);
  }

  @override
  Future<(List<Node>, bool)> timeline({DateTime? before, int limit = 100, String? category}) async {
    final s = await _ensure();
    return _page(
        s,
        s.nodes.where((n) =>
            n.timeline &&
            (category == null ||
                category.isEmpty ||
                (category == 'none' ? n.categoryId.isEmpty : n.categoryId == category))),
        before,
        limit);
  }

  @override
  Future<(List<Node>, bool)> tagged(String categoryId, {DateTime? before, int limit = 100}) async {
    final s = await _ensure();
    return _page(s, s.nodes.where((n) => n.categoryId == categoryId), before, limit);
  }

  @override
  Future<List<Node>> search(String q) async {
    final s = await _ensure();
    final ql = q.toLowerCase();
    return _page(s, s.nodes.where((n) => n.parentId.isNotEmpty && n.name.toLowerCase().contains(ql)), null, 300).$1;
  }

  @override
  Future<List<Node>> trashList() async {
    final s = await _ensure();
    return s.trash.map(s.located).toList();
  }

  // --- changes (sealed ops; optimistic where it's safe) ---

  @override
  Future<Node> patchNode(String id, {String? name, String? parentId, String? categoryId, bool? timeline}) async {
    final s = await _ensure();
    final n = s.byId[id];
    if (n == null) throw ApiException(404, 'not_found', '文件或对象不存在');
    final pid = parentId == null ? null : (parentId.isEmpty ? s.user.rootId : parentId);
    await _op({'t': 'patch', 'id': id, 'name': ?name, 'parent_id': ?pid, 'category_id': ?categoryId},
        optimistic: (snap) {
      final cur = snap.byId[id];
      if (cur != null) snap.replace(cur.copyWith(name: name, parentId: pid, categoryId: categoryId));
    });
    return n.copyWith(name: name, parentId: pid, categoryId: categoryId);
  }

  @override
  Future<void> trash(String id) => batch('trash', [id]);

  @override
  Future<Map<String, String>> batch(String action, List<String> ids, {String? parentId, String? categoryId}) async {
    final s = await _ensure();
    final pid = parentId == null ? null : (parentId.isEmpty ? s.user.rootId : parentId);
    await _op({'t': 'batch', 'action': action, 'ids': ids, 'parent_id': ?pid, 'category_id': ?categoryId},
        optimistic: (snap) {
      for (final id in ids) {
        final cur = snap.byId[id];
        if (cur == null) continue;
        switch (action) {
          case 'trash':
            final gone = snap.removeSubtree(id);
            if (gone != null && !snap.trash.any((t) => t.id == id)) snap.trash = [gone, ...snap.trash];
          case 'move':
            snap.replace(cur.copyWith(parentId: pid));
          case 'categorize':
            snap.replace(cur.copyWith(categoryId: categoryId ?? ''));
        }
      }
    });
    return const {};
  }

  @override
  Future<Node> createFolder({
    String? parentId,
    String? categoryId,
    String? name,
    String? path,
    String conflict = 'fail',
    bool timeline = false,
    int? mtime,
  }) async {
    final s = await _ensure();
    final r = await _op({
      't': 'mkdir',
      'parent_id': ?parentId,
      'category_id': ?categoryId,
      'name': ?name,
      'path': ?path,
    }, wait: true, timeout: const Duration(minutes: 2));
    final id = (r['id'] as String?) ?? '';
    await _fetchSnapshot().catchError((_) => null);
    return _snap?.byId[id] ?? s.byId[s.user.rootId]!;
  }

  @override
  Future<Node> restore(String id) async {
    final s = await _ensure();
    final n = s.trash.firstWhere((t) => t.id == id, orElse: () => throw ApiException(404, 'not_found', '文件或对象不存在'));
    await _op({'t': 'restore', 'id': id}, optimistic: (snap) => snap.trash = snap.trash.where((t) => t.id != id).toList());
    return n;
  }

  ApiException get _policyPurge =>
      ApiException(403, 'policy', 'NAS 设置不允许远程彻底删除，请在局域网内操作（文件仍在回收站中）');

  @override
  Future<void> purge(String id) async {
    if (!canPurge) throw _policyPurge;
    await _op({'t': 'purge', 'id': id}, optimistic: (snap) => snap.trash = snap.trash.where((t) => t.id != id).toList());
  }

  @override
  Future<void> emptyTrash() async {
    if (!canPurge) throw _policyPurge;
    await _op({'t': 'empty_trash'}, optimistic: (snap) => snap.trash = []);
  }

  @override
  Future<Category> createCategory(String name, String color, String icon) async {
    final r = await _op({'t': 'cat_create', 'name': name, 'color': color, 'icon': icon},
        wait: true, timeout: const Duration(minutes: 2));
    await _fetchSnapshot().catchError((_) => null);
    final id = r['id'] as String? ?? '';
    return _snap?.categories.where((c) => c.id == id).firstOrNull ??
        Category(id: id, name: name, color: Category.parseColor(color), icon: icon, sort: 0, folderId: '', count: 0);
  }

  @override
  Future<Category> updateCategory(String id, {String? name, String? color, String? icon, String? folderId}) async {
    await _op({'t': 'cat_update', 'id': id, 'name': ?name, 'color': ?color, 'icon': ?icon, 'folder_id': ?folderId},
        optimistic: (snap) {
      snap.categories = [
        for (final c in snap.categories)
          c.id != id
              ? c
              : Category(
                  id: c.id,
                  name: name ?? c.name,
                  color: color == null ? c.color : Category.parseColor(color),
                  icon: icon ?? c.icon,
                  sort: c.sort,
                  folderId: folderId ?? c.folderId,
                  count: c.count),
      ];
    });
    return (await _ensure()).categories.firstWhere((c) => c.id == id);
  }

  @override
  Future<void> deleteCategory(String id) => _op({'t': 'cat_delete', 'id': id},
      optimistic: (snap) => snap.categories = snap.categories.where((c) => c.id != id).toList());

  @override
  Future<void> reorderCategories(List<String> ids) => _op({'t': 'cat_reorder', 'ids': ids});

  @override
  Future<void> renameDevice(String id, String name) => _op({'t': 'device_rename', 'id': id, 'name': name});

  @override
  Future<void> revokeDevice(String id) => _op({'t': 'device_revoke', 'id': id},
      optimistic: (snap) => snap.devices = snap.devices.where((d) => d.id != id).toList());

  @override
  Future<void> logout() async {
    try {
      await _op({'t': 'device_revoke', 'id': creds.deviceId});
    } catch (_) {}
  }

  @override
  Future<(String, DateTime)> createPairingCode() async {
    final r = await _op({'t': 'pair'}, wait: true, timeout: const Duration(minutes: 3));
    return (r['code'] as String, DateTime.fromMillisecondsSinceEpoch((r['expires'] as num).toInt()));
  }

  static ApiException get _lanOnly => ApiException(0, 'lan_only', '该功能只能在局域网直连 NAS 时使用');

  @override
  Future<void> changePassword(String oldPw, String newPw, {bool signOutOthers = false}) => throw _lanOnly;
  @override
  Future<List<AuditEntry>> audit() => throw _lanOnly;
  @override
  Future<List<User>> users() => throw _lanOnly;
  @override
  Future<void> createUser(String username, String password, bool admin) => throw _lanOnly;
  @override
  Future<void> deleteUser(String id) => throw _lanOnly;
  @override
  Future<void> resetPassword(String id, String password) => throw _lanOnly;

  // --- transfers ---

  /// Encrypts a file and uploads the ciphertext to the relay (resumable).
  /// Returns the relay blob id and the blob's header nonce for the op.
  Future<(String, String)> uploadBlob(File f, int size, {void Function(int sent)? onProgress, CancelToken? cancel}) async {
    var ring = creds.keyring;
    var kid = creds.current;
    if (ring[kid] == null) {
      await _refreshKeyring();
      ring = creds.keyring;
      kid = creds.current;
    }
    final enc = await BlobEncryptor.create(f.path, size, kid, ring[kid]!);
    final total = enc.length;
    final created = await _call('POST', '/r/v1/blobs', json: {'size': total}) as Map;
    final id = created['id'] as String;
    var received = 0;
    var failures = 0;
    while (received < total) {
      cancel?.check();
      try {
        final end = min(received + (8 << 20), total);
        final data = await enc.range(received, end);
        final resp = await _send('PUT', '/r/v1/blobs/$id', bytes: data, query: {'offset': '$received'}, cancel: cancel);
        final text = await utf8.decodeStream(resp);
        final j = text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map).cast<String, dynamic>();
        if (resp.statusCode == 409 && j['received'] is num) {
          received = (j['received'] as num).toInt();
          continue;
        }
        if (resp.statusCode >= 400) {
          throw ApiException(resp.statusCode, 'relay', ((j['error'] as Map?)?['message'] as String?) ?? '上传失败');
        }
        received = (j['received'] as num).toInt();
        failures = 0;
        onProgress?.call((received * size / total).floor());
      } on ApiException catch (e) {
        if (!e.network || ++failures > 10) rethrow;
        await Future.delayed(Duration(seconds: min(30, 1 << failures)));
        final st = await _call('GET', '/r/v1/blobs/$id').catchError((_) => <String, dynamic>{'received': received});
        received = ((st as Map)['received'] as num).toInt();
      }
    }
    return (id, enc.nonceB64);
  }

  /// Asks the NAS to ingest uploaded blobs; resolves once it has.
  Future<Map<String, dynamic>> commitUpload(Map<String, dynamic> op) =>
      _op({'t': 'upload', ...op}, wait: true, timeout: const Duration(hours: 2));

  Future<Set<String>> _present(List<String> keys) async {
    final out = <String>{};
    for (var i = 0; i < keys.length; i += 2000) {
      final j = await _call('POST', '/r/v1/cache/lookup', json: {'keys': keys.sublist(i, min(i + 2000, keys.length))}) as Map;
      for (final p in (j['present'] as List).cast<Map>()) {
        out.add(p['key'] as String);
      }
    }
    return out;
  }

  Future<String> _cacheKeyOf(Node n) async {
    final s = await _ensure();
    var sk = creds.keyring[s.kid];
    if (sk == null) {
      await _refreshKeyring();
      sk = creds.keyring[s.kid];
    }
    if (sk == null) throw ApiException(0, 'key', '缺少解密密钥，请重新配对此设备');
    return cacheKey(sk, n.id, n.sha256);
  }

  /// Asks the NAS to put encrypted copies of files on the relay (one op).
  Future<void> prefetch(List<Node> files) async {
    final now = DateTime.now();
    _requested.removeWhere((_, t) => now.difference(t) > const Duration(minutes: 10));
    final keys = {for (final n in files) n.id: await _cacheKeyOf(n)};
    final present = await _present(keys.values.toList());
    final need = [for (final n in files) if (!present.contains(keys[n.id]) && !_requested.containsKey(n.id)) n.id];
    for (var i = 0; i < need.length; i += 5000) {
      final ids = need.sublist(i, min(i + 5000, need.length));
      await _op({'t': 'fetch', 'ids': ids});
      for (final id in ids) {
        _requested[id] = now;
      }
    }
  }

  Future<void> _waitCached(String key, CancelToken? cancel) async {
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (true) {
      cancel?.check();
      if ((await _present([key])).isNotEmpty) return;
      if (DateTime.now().isAfter(deadline)) {
        throw ApiException(0, 'nas_offline', 'NAS 长时间未发送该文件（可能离线）');
      }
      final c = _cacheWaiters[key] ??= Completer<void>();
      await Future.any([c.future, Future.delayed(const Duration(seconds: 8))]);
    }
  }

  @override
  Future<void> download(Node n, File target,
      {void Function(int got)? onProgress, CancelToken? cancel, void Function(String? phase)? onPhase}) async {
    final total = cipherSize(n.size);
    final enc = File('${target.path}.fsdownload.enc');
    for (var attempt = 0; attempt < 2; attempt++) {
      final key = await _cacheKeyOf(n);
      var have = await enc.exists() ? await enc.length() : 0;
      if (have > total) {
        await enc.delete();
        have = 0;
      }
      if (have < total && (await _present([key])).isEmpty) {
        onPhase?.call('等待 NAS 发送…');
        await prefetch([n]);
        await _waitCached(key, cancel);
        onPhase?.call(null);
      }
      var failures = 0;
      while (have < total) {
        cancel?.check();
        try {
          final resp = await _send('GET', '/r/v1/cache/$key',
              headers: {if (have > 0) HttpHeaders.rangeHeader: 'bytes=$have-'}, cancel: cancel);
          if (resp.statusCode == 404) {
            await resp.drain<void>();
            onPhase?.call('等待 NAS 发送…');
            _requested.remove(n.id);
            await prefetch([n]);
            await _waitCached(key, cancel);
            onPhase?.call(null);
            continue;
          }
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            await resp.drain<void>();
            throw ApiException(resp.statusCode, 'relay', '下载失败 (${resp.statusCode})');
          }
          final sink = enc.openWrite(mode: resp.statusCode == 206 ? FileMode.append : FileMode.write);
          if (resp.statusCode == 200) have = 0;
          try {
            await sink.addStream(resp.timeout(const Duration(seconds: 60)).map((c) {
              have += c.length;
              onProgress?.call((have * n.size / total).floor());
              return c;
            }));
          } finally {
            await sink.close();
          }
          failures = 0;
        } on ApiException catch (e) {
          if (!e.network || ++failures > 8) rethrow;
          await Future.delayed(Duration(seconds: min(30, 1 << failures)));
          have = await enc.exists() ? await enc.length() : 0;
        } on TimeoutException {
          if (++failures > 8) rethrow;
          have = await enc.exists() ? await enc.length() : 0;
        }
      }
      onPhase?.call('正在解密校验…');
      final tmp = '${target.path}.fsdownload';
      try {
        await decryptFile(enc.path, tmp, n.size, creds.keyring, n.sha256);
      } on E2EAuthError {
        // stale or foreign copy (e.g. after a key rotation): fetch it again once
        await enc.delete();
        if (await File(tmp).exists()) await File(tmp).delete();
        if (attempt == 0) {
          await _refreshKeyring();
          continue;
        }
        rethrow;
      }
      await File(tmp).rename(target.path);
      await enc.delete();
      onPhase?.call(null);
      try {
        await target.setLastModified(n.mtime);
      } catch (_) {}
      return;
    }
  }

  @override
  Future<Uint8List> bytes(Node n, {int maxBytes = 32 << 20}) async {
    if (n.size > maxBytes) throw ApiException(0, 'too_large', '文件过大，无法预览');
    final dir = await Directory.systemTemp.createTemp('fs-preview');
    try {
      final f = File('${dir.path}/f');
      await download(n, f);
      return await f.readAsBytes();
    } finally {
      await dir.delete(recursive: true);
    }
  }

  // --- pairing (no credentials yet) ---

  static Uint8List _base32(String s) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final out = <int>[];
    var buf = 0, bits = 0;
    for (final ch in s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '').split('')) {
      final v = alphabet.indexOf(ch);
      if (v < 0) throw const FormatException('配对码格式不正确');
      buf = (buf << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buf >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }

  /// Enrolls this device with a pairing code from the NAS. Returns the
  /// credentials once the NAS (on its next sync) has accepted the request.
  static Future<RelayCreds> pair(String code, String deviceName, String platform,
      {void Function(String status)? onStatus, CancelToken? cancel}) async {
    final u = Uri.tryParse(code.trim());
    if (u == null || u.scheme != 'fileswitch' || u.host != 'pair' || u.queryParameters['k'] == null) {
      throw const FormatException('请粘贴完整的配对码（以 fileswitch://pair 开头）');
    }
    final secret = _base32(u.queryParameters['k']!);
    if (secret.length != 16) throw const FormatException('配对码不完整');
    final relay = (u.queryParameters['r'] ?? '').replaceAll(RegExp(r'/+$'), '');
    if (!relay.startsWith('https://')) throw const FormatException('配对码中的中转站地址无效');
    final fp = u.queryParameters['f'];
    final (lookup, key) = await pairing(secret);
    final http = _pinnedClient(fp);
    final base = Uri.parse(relay);
    Uri at(String p) => base.replace(path: '${base.path}$p');
    try {
      onStatus?.call('正在连接中转站…');
      final req = await http.postUrl(at('/r/v1/pair/$lookup'));
      final body = utf8.encode(jsonEncode(
          await sealEnvelope(key, utf8.encode(jsonEncode({'device_name': deviceName, 'platform': platform})), pairReqAAD(lookup))));
      req.headers.contentType = ContentType.json;
      req.contentLength = body.length;
      req.add(body);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      await resp.drain<void>();
      if (resp.statusCode != 202) throw ApiException(resp.statusCode, 'pair', '中转站拒绝了配对请求 (${resp.statusCode})');
      onStatus?.call('等待 NAS 确认（NAS 会在下次同步时处理，通常不超过半分钟）…');
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(deadline)) {
        cancel?.check();
        await Future.delayed(const Duration(seconds: 2));
        final r = await http.getUrl(at('/r/v1/pair/$lookup'));
        final rr = await r.close().timeout(const Duration(seconds: 30));
        final text = await utf8.decodeStream(rr);
        if (rr.statusCode != 200) continue;
        final p = await openEnvelope(key, jsonDecode(text) as Map, pairRespAAD(lookup));
        return RelayCreds((jsonDecode(utf8.decode(p)) as Map).cast<String, dynamic>());
      }
      throw ApiException(0, 'timeout', 'NAS 没有回应。配对码可能已过期或已被使用，也可能 NAS 不在线');
    } on ApiException {
      rethrow;
    } on FormatException {
      rethrow;
    } on E2EAuthError {
      throw ApiException(0, 'auth', '配对回复无法验证，请重新生成配对码');
    } catch (e) {
      throw _wrapNet(e);
    } finally {
      http.close(force: true);
    }
  }
}
