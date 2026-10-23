import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'backend.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.body});
  final int status; // 0 = network / TLS failure
  final String code;
  final String message;
  final Map<String, dynamic>? body;

  bool get unauthorized => status == 401;
  bool get network => status == 0;

  @override
  String toString() => message;
}

/// The server presented a different certificate than the one pinned for it.
class CertificateChangedException extends ApiException {
  CertificateChangedException(this.fingerprint)
      : super(0, 'cert_changed', '服务器证书与之前信任的不一致，可能存在中间人攻击。若服务器确实更换了证书，请删除该服务器后重新添加。');
  final String fingerprint;
}

class CanceledException implements Exception {
  @override
  String toString() => '已取消';
}

class CancelToken {
  bool _canceled = false;
  final _hooks = <void Function()>[];

  bool get isCanceled => _canceled;

  void cancel() {
    if (_canceled) return;
    _canceled = true;
    for (final h in List.of(_hooks)) {
      h();
    }
  }

  void Function() onCancel(void Function() hook) {
    _hooks.add(hook);
    return () => _hooks.remove(hook);
  }

  void check() {
    if (_canceled) throw CanceledException();
  }
}

String certFingerprint(X509Certificate cert) =>
    sha256.convert(cert.der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

/// An HttpClient that only talks to the server with this certificate.
///
/// badCertificateCallback only runs for certificates the platform rejects, so
/// with the system roots loaded a CA-signed certificate for the same host
/// would be accepted without ever looking at the pin. Without any trusted
/// roots every certificate goes through the callback.
HttpClient pinnedHttpClient(String? fingerprint, {void Function(String fp)? seen}) {
  final c = HttpClient(context: fingerprint == null ? null : SecurityContext(withTrustedRoots: false));
  final want = fingerprint == null ? null : _normFp(fingerprint);
  c.badCertificateCallback = (cert, host, port) {
    final fp = certFingerprint(cert);
    seen?.call(fp);
    return want != null && _normFp(fp) == want;
  };
  return c;
}

String _normFp(String s) => s.replaceAll(':', '').toUpperCase();

/// Accepts "nas.local", "192.168.1.5:8443", "https://files.example.com/fs".
/// Without a scheme we assume https on the default FileSwitch port 8443.
Uri normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) throw const FormatException('请输入服务器地址');
  final hadScheme = s.contains('://');
  if (!hadScheme) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) throw const FormatException('服务器地址格式不正确');
  if (u.scheme != 'https') throw const FormatException('只支持 https:// 地址（密码和令牌不能明文传输）');
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  int? port = u.hasPort ? u.port : null;
  if (!hadScheme && port == null) port = 8443;
  return Uri(scheme: u.scheme, host: u.host, port: port, path: path);
}

class ProbeResult {
  ProbeResult(this.url, this.info, this.fingerprint);
  final Uri url;
  final ServerInfo info;

  /// Fingerprint of a certificate the OS doesn't trust (self-signed); null when
  /// the OS already trusts it.
  final String? fingerprint;
}

class ApiClient implements Backend {
  ApiClient({required this.base, this.fingerprint, this.token}) {
    _http = pinnedHttpClient(fingerprint, seen: (fp) => _seenFingerprint = fp)
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 8
      ..userAgent = 'FileSwitch/1.0';
  }

  final Uri base;
  final String? fingerprint;
  String? token;
  late final HttpClient _http;
  String? _seenFingerprint;

  /// Files up to this size go in a single request; bigger ones use a
  /// resumable chunked session.
  static const directLimit = 4 << 20;

  @override
  bool get isRemote => false;

  @override
  String get modeLabel => '局域网直连';

  @override
  bool get canPurge => true;

  @override
  void close() => _http.close(force: true);

  /// Asks the NAS for relay credentials for this (LAN-authenticated) device.
  Future<Map<String, dynamic>> enrollRelay() async => _map(await _json('POST', '/relay/enroll'));

  @override
  Future<(String, DateTime)> createPairingCode() async {
    final j = _map(await _json('POST', '/relay/pair'));
    return (j['code'] as String, DateTime.fromMillisecondsSinceEpoch((j['expires'] as num).toInt()));
  }

  /// Connects without credentials to read /info and capture the certificate.
  static Future<ProbeResult> probe(String input) async {
    final url = normalizeServerUrl(input);
    String? seen;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    // Accepting here is fine: nothing secret is sent, and the user must confirm
    // the fingerprint before we ever send a password.
    c.badCertificateCallback = (cert, host, port) {
      seen = certFingerprint(cert);
      return true;
    };
    try {
      final req = await c.getUrl(url.replace(path: '${url.path}/api/v1/info'));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final text = await utf8.decodeStream(resp);
      if (resp.statusCode != 200) {
        throw ApiException(resp.statusCode, 'not_fileswitch', '该地址不是 FileSwitch 服务器 (HTTP ${resp.statusCode})');
      }
      final j = jsonDecode(text);
      if (j is! Map || j['api'] == null) throw ApiException(0, 'not_fileswitch', '该地址不是 FileSwitch 服务器');
      return ProbeResult(url, ServerInfo.fromJson(j.cast<String, dynamic>()), seen);
    } on ApiException {
      rethrow;
    } on FormatException {
      throw ApiException(0, 'not_fileswitch', '该地址不是 FileSwitch 服务器');
    } on TimeoutException {
      throw ApiException(0, 'timeout', '连接超时');
    } on SocketException catch (e) {
      throw ApiException(0, 'network', '无法连接: ${e.osError?.message ?? e.message}');
    } on HandshakeException catch (e) {
      throw ApiException(0, 'tls', 'TLS 握手失败: ${e.message}');
    } on HttpException catch (e) {
      throw ApiException(0, 'network', '连接失败: ${e.message}');
    } finally {
      c.close(force: true);
    }
  }

  Uri uri(String path, [Map<String, String>? query]) => base.replace(
        path: '${base.path}/api/v1$path',
        queryParameters: (query == null || query.isEmpty) ? null : query,
      );

  ApiException _wrap(Object e) {
    if (e is ApiException) return e;
    if (e is HandshakeException || e is TlsException) {
      if (fingerprint != null && _seenFingerprint != null && _seenFingerprint != fingerprint) {
        return CertificateChangedException(_seenFingerprint!);
      }
      return ApiException(0, 'tls', '安全连接失败');
    }
    if (e is SocketException) return ApiException(0, 'network', '无法连接服务器');
    if (e is HttpException) return ApiException(0, 'network', '连接中断');
    if (e is TimeoutException) return ApiException(0, 'timeout', '请求超时');
    if (e is CanceledException) throw e;
    return ApiException(0, 'network', e.toString());
  }

  Future<HttpClientRequest> _open(String method, Uri u) async {
    try {
      final req = await _http.openUrl(method, u);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      return req;
    } catch (e) {
      throw _wrap(e);
    }
  }

  ApiException _errorFrom(int status, dynamic data) {
    if (data is Map && data['error'] is Map) {
      final e = data['error'] as Map;
      return ApiException(status, (e['code'] as String?) ?? 'error', (e['message'] as String?) ?? 'HTTP $status',
          body: data.cast<String, dynamic>());
    }
    return ApiException(status, 'http', 'HTTP $status');
  }

  Future<dynamic> _json(String method, String path,
      {Map<String, String>? query, Object? body, Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final req = await _open(method, uri(path, query));
      if (body != null) {
        final b = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = b.length;
        req.add(b);
      }
      final resp = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(resp).timeout(timeout);
      dynamic data;
      if (text.isNotEmpty) {
        try {
          data = jsonDecode(text);
        } on FormatException {
          data = null;
        }
      }
      if (resp.statusCode >= 400) throw _errorFrom(resp.statusCode, data);
      return data;
    } catch (e) {
      throw _wrap(e);
    }
  }

  Map<String, dynamic> _map(dynamic d) => (d as Map).cast<String, dynamic>();
  List<Node> _nodes(dynamic list) => (list as List).map((e) => Node.fromJson(_map(e))).toList();

  // --- auth & account ---

  Future<(String, User, Device)> login(String username, String password, String deviceName, String platform) async {
    final j = _map(await _json('POST', '/auth/login', body: {
      'username': username,
      'password': password,
      'device_name': deviceName,
      'platform': platform,
    }));
    return (j['token'] as String, User.fromJson(_map(j['user'])), Device.fromJson(_map(j['device'])));
  }

  @override
  Future<(User, Device)> me() async {
    final j = _map(await _json('GET', '/auth/me'));
    return (User.fromJson(_map(j['user'])), Device.fromJson(_map(j['device'])));
  }

  @override
  Future<void> logout() => _json('POST', '/auth/logout', timeout: const Duration(seconds: 5));

  @override
  Future<void> changePassword(String oldPw, String newPw, {bool signOutOthers = false}) =>
      _json('POST', '/auth/password',
          body: {'old_password': oldPw, 'new_password': newPw, 'sign_out_others': signOutOthers});

  @override
  Future<(List<Device>, String)> devices() async {
    final j = _map(await _json('GET', '/devices'));
    return ((j['devices'] as List).map((e) => Device.fromJson(_map(e))).toList(), j['current'] as String);
  }

  @override
  Future<void> renameDevice(String id, String name) => _json('PATCH', '/devices/$id', body: {'name': name});
  @override
  Future<void> revokeDevice(String id) => _json('DELETE', '/devices/$id');

  @override
  Future<List<AuditEntry>> audit() async {
    final j = _map(await _json('GET', '/audit'));
    return (j['entries'] as List).map((e) => AuditEntry.fromJson(_map(e))).toList();
  }

  @override
  Future<Stats> stats() async => Stats.fromJson(_map(await _json('GET', '/stats')));

  @override
  Future<ServerInfo> info() async => ServerInfo.fromJson(_map(await _json('GET', '/info')));

  // --- admin ---

  @override
  Future<List<User>> users() async {
    final j = _map(await _json('GET', '/admin/users'));
    return (j['users'] as List).map((e) => User.fromJson(_map(e))).toList();
  }

  @override
  Future<void> createUser(String username, String password, bool admin) =>
      _json('POST', '/admin/users', body: {'username': username, 'password': password, 'is_admin': admin});
  @override
  Future<void> deleteUser(String id) => _json('DELETE', '/admin/users/$id');
  @override
  Future<void> resetPassword(String id, String password) =>
      _json('POST', '/admin/users/$id/password', body: {'password': password});

  // --- categories ---

  @override
  Future<List<Category>> categories() async {
    final j = _map(await _json('GET', '/categories'));
    return (j['categories'] as List).map((e) => Category.fromJson(_map(e))).toList();
  }

  @override
  Future<Category> createCategory(String name, String color, String icon) async =>
      Category.fromJson(_map(await _json('POST', '/categories', body: {'name': name, 'color': color, 'icon': icon})));

  @override
  Future<Category> updateCategory(String id, {String? name, String? color, String? icon, String? folderId}) async =>
      Category.fromJson(_map(await _json('PATCH', '/categories/$id', body: {
        'name': ?name,
        'color': ?color,
        'icon': ?icon,
        'folder_id': ?folderId,
      })));

  @override
  Future<void> deleteCategory(String id) => _json('DELETE', '/categories/$id');
  @override
  Future<void> reorderCategories(List<String> ids) => _json('POST', '/categories/reorder', body: {'ids': ids});

  // --- tree ---

  @override
  Future<Listing> list(String? parentId, {bool dirsOnly = false}) async {
    final j = _map(await _json('GET', '/nodes', query: {
      if (parentId != null && parentId.isNotEmpty) 'parent': parentId,
      if (dirsOnly) 'dirs': '1',
    }));
    return Listing(Node.fromJson(_map(j['parent'])),
        (j['path'] as List).map((e) => Crumb.fromJson(_map(e))).toList(), _nodes(j['children']));
  }

  @override
  Future<(Node, List<Crumb>)> node(String id) async {
    final j = _map(await _json('GET', '/nodes/$id'));
    return (Node.fromJson(_map(j['node'])), (j['path'] as List).map((e) => Crumb.fromJson(_map(e))).toList());
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
  }) async =>
      Node.fromJson(_map(await _json('POST', '/nodes/folder', body: {
        'parent_id': ?parentId,
        'category_id': ?categoryId,
        'name': ?name,
        'path': ?path,
        'conflict': conflict,
        'timeline': timeline,
        'mtime': ?mtime,
      })));

  @override
  Future<Node> patchNode(String id, {String? name, String? parentId, String? categoryId, bool? timeline}) async =>
      Node.fromJson(_map(await _json('PATCH', '/nodes/$id', body: {
        'name': ?name,
        'parent_id': ?parentId,
        'category_id': ?categoryId,
        'timeline': ?timeline,
      })));

  @override
  Future<void> trash(String id) => _json('DELETE', '/nodes/$id');

  /// Returns the ids that failed with their error message.
  @override
  Future<Map<String, String>> batch(String action, List<String> ids, {String? parentId, String? categoryId}) async {
    final j = _map(await _json('POST', '/nodes/batch', body: {
      'action': action,
      'ids': ids,
      'parent_id': ?parentId,
      'category_id': ?categoryId,
    }));
    return {
      for (final r in (j['results'] as List).map(_map))
        if (r['ok'] != true) r['id'] as String: (r['error'] as String?) ?? '失败',
    };
  }

  @override
  Future<List<WalkEntry>> walk(String id) async {
    final j = _map(await _json('GET', '/nodes/$id/walk', timeout: const Duration(minutes: 2)));
    return (j['entries'] as List).map((e) {
      final m = _map(e);
      return WalkEntry(Node.fromJson(m), m['rel_path'] as String);
    }).toList();
  }

  @override
  Future<(List<Node>, bool)> timeline({DateTime? before, int limit = 100, String? category}) async {
    final j = _map(await _json('GET', '/timeline', query: {
      if (before != null) 'before': '${before.millisecondsSinceEpoch}',
      'limit': '$limit',
      if (category != null && category.isNotEmpty) 'category': category,
    }));
    return (_nodes(j['items']), j['has_more'] == true);
  }

  @override
  Future<(List<Node>, bool)> tagged(String categoryId, {DateTime? before, int limit = 100}) async {
    final j = _map(await _json('GET', '/tagged/$categoryId', query: {
      if (before != null) 'before': '${before.millisecondsSinceEpoch}',
      'limit': '$limit',
    }));
    return (_nodes(j['items']), j['has_more'] == true);
  }

  @override
  Future<List<Node>> search(String q) async => _nodes(_map(await _json('GET', '/search', query: {'q': q}))['items']);

  @override
  Future<List<Node>> trashList() async => _nodes(_map(await _json('GET', '/trash'))['items']);
  @override
  Future<Node> restore(String id) async => Node.fromJson(_map(await _json('POST', '/trash/$id/restore')));
  @override
  Future<void> purge(String id) => _json('DELETE', '/trash/$id');
  @override
  Future<void> emptyTrash() => _json('DELETE', '/trash');

  // --- transfers ---

  /// Uploads [file] as [relPath] below the destination. Folders in relPath are
  /// created as needed. Large files resume automatically after network errors.
  Future<Node> uploadFile(
    File file, {
    String? parentId,
    String? categoryId,
    required String relPath,
    bool timeline = false,
    String conflict = 'rename',
    void Function(int sent)? onProgress,
    CancelToken? cancel,
  }) async {
    final size = await file.length();
    final mtime = (await file.lastModified()).millisecondsSinceEpoch;
    if (size <= directLimit) {
      return _retry(cancel, () => _uploadDirect(file, size, mtime,
          parentId: parentId,
          categoryId: categoryId,
          relPath: relPath,
          timeline: timeline,
          conflict: conflict,
          onProgress: onProgress,
          cancel: cancel));
    }
    final created = _map(await _retry(
        cancel,
        () => _json('POST', '/uploads', body: {
              'parent_id': ?parentId,
              'category_id': ?categoryId,
              'path': relPath,
              'size': size,
              'mtime': mtime,
              'timeline': timeline,
              'conflict': conflict,
            })));
    final up = _map(created['upload']);
    final id = up['id'] as String;
    final chunk = (created['chunk_size'] as num).toInt();
    var received = (up['received'] as num).toInt();
    var failures = 0;
    try {
      while (received < size) {
        cancel?.check();
        try {
          received = await _putChunk(id, file, received, min(received + chunk, size), onProgress, cancel);
          failures = 0;
        } on ApiException catch (e) {
          final r = e.body?['received'];
          if (e.status == 409 && r is num) {
            received = r.toInt();
            continue;
          }
          if (!e.network || ++failures > 10) rethrow;
          await Future.delayed(Duration(seconds: min(30, 1 << failures)));
          cancel?.check();
          try {
            received = (_map(_map(await _json('GET', '/uploads/$id'))['upload'])['received'] as num).toInt();
          } on ApiException catch (e) {
            if (!e.network) rethrow;
          }
        }
      }
      final done = _map(await _retry(cancel, () => _json('POST', '/uploads/$id/complete')));
      return Node.fromJson(_map(done['node']));
    } on CanceledException {
      _json('DELETE', '/uploads/$id').ignore();
      rethrow;
    }
  }

  /// Retries [fn] on network errors with backoff.
  Future<T> _retry<T>(CancelToken? cancel, Future<T> Function() fn) async {
    for (var attempt = 1;; attempt++) {
      cancel?.check();
      try {
        return await fn();
      } on ApiException catch (e) {
        if (!e.network || e is CertificateChangedException || attempt >= 6) rethrow;
        await Future.delayed(Duration(seconds: min(20, 1 << attempt)));
      }
    }
  }

  Future<Node> _uploadDirect(
    File file,
    int size,
    int mtime, {
    String? parentId,
    String? categoryId,
    required String relPath,
    required bool timeline,
    required String conflict,
    void Function(int)? onProgress,
    CancelToken? cancel,
  }) async {
    final req = await _open(
        'PUT',
        uri('/files', {
          'path': relPath,
          'size': '$size',
          'mtime': '$mtime',
          'conflict': conflict,
          if (timeline) 'timeline': '1',
          'parent_id': ?parentId,
          'category_id': ?categoryId,
        }));
    final unhook = cancel?.onCancel(() => req.abort(CanceledException()));
    try {
      req.contentLength = size;
      req.headers.contentType = ContentType.binary;
      var sent = 0;
      await req.addStream(file.openRead().map((c) {
        sent += c.length;
        onProgress?.call(sent);
        return c;
      }));
      final resp = await req.close().timeout(const Duration(minutes: 2));
      final text = await utf8.decodeStream(resp);
      final data = text.isEmpty ? null : jsonDecode(text);
      if (resp.statusCode >= 400) throw _errorFrom(resp.statusCode, data);
      return Node.fromJson(_map(_map(data)['node']));
    } catch (e) {
      cancel?.check();
      throw _wrap(e);
    } finally {
      unhook?.call();
    }
  }

  Future<int> _putChunk(String id, File file, int start, int end, void Function(int)? onProgress, CancelToken? cancel) async {
    final req = await _open('PUT', uri('/uploads/$id', {'offset': '$start'}));
    final unhook = cancel?.onCancel(() => req.abort(CanceledException()));
    try {
      req.contentLength = end - start;
      req.headers.contentType = ContentType.binary;
      var sent = start;
      await req.addStream(file.openRead(start, end).map((c) {
        sent += c.length;
        onProgress?.call(sent);
        return c;
      }));
      final resp = await req.close().timeout(const Duration(minutes: 5));
      final text = await utf8.decodeStream(resp);
      final data = text.isEmpty ? null : jsonDecode(text);
      if (resp.statusCode >= 400) throw _errorFrom(resp.statusCode, data);
      if (data == null) throw ApiException(0, 'network', '连接中断');
      return (_map(data)['received'] as num).toInt();
    } catch (e) {
      cancel?.check();
      throw _wrap(e);
    } finally {
      unhook?.call();
    }
  }

  /// Downloads a file to [target], resuming a previous partial download.
  @override
  Future<void> download(Node n, File target,
      {void Function(int got)? onProgress, CancelToken? cancel, void Function(String? phase)? onPhase}) async {
    final part = File('${target.path}.fsdownload');
    var failures = 0;
    while (true) {
      cancel?.check();
      var have = await part.exists() ? await part.length() : 0;
      if (have > n.size) {
        await part.delete();
        have = 0;
      }
      try {
        if (have == n.size && n.size > 0) break;
        final req = await _open('GET', uri('/nodes/${n.id}/content'));
        if (have > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
          if (n.sha256.isNotEmpty) req.headers.set(HttpHeaders.ifRangeHeader, '"${n.sha256}"');
        }
        final unhook = cancel?.onCancel(() => req.abort(CanceledException()));
        try {
          final resp = await req.close().timeout(const Duration(seconds: 30));
          if (resp.statusCode == 416) {
            await resp.drain<void>();
            await part.delete();
            continue;
          }
          if (resp.statusCode >= 400) {
            final text = await utf8.decodeStream(resp);
            throw _errorFrom(resp.statusCode, text.isEmpty ? null : jsonDecode(text));
          }
          final append = resp.statusCode == 206;
          var got = append ? have : 0;
          final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
          try {
            await sink.addStream(resp.timeout(const Duration(seconds: 60)).map((c) {
              got += c.length;
              onProgress?.call(got);
              return c;
            }));
          } finally {
            await sink.close();
          }
        } finally {
          unhook?.call();
        }
        break;
      } catch (e) {
        cancel?.check();
        final ae = _wrap(e);
        if (!ae.network || ae is CertificateChangedException || ++failures > 8) throw ae;
        await Future.delayed(Duration(seconds: min(30, 1 << failures)));
      }
    }
    if (!await part.exists()) await part.create(recursive: true);
    if (await part.length() != n.size) throw ApiException(0, 'incomplete', '下载不完整');
    if (n.sha256.isNotEmpty && (await sha256.bind(part.openRead()).first).toString() != n.sha256) {
      await part.delete();
      throw ApiException(0, 'corrupt', '下载的文件校验失败，请重试');
    }
    await part.rename(target.path);
    try {
      await target.setLastModified(n.mtime);
    } catch (_) {}
  }

  /// Fetches a small file into memory (for previews).
  @override
  Future<Uint8List> bytes(Node n, {int maxBytes = 32 << 20}) async {
    if (n.size > maxBytes) throw ApiException(0, 'too_large', '文件过大，无法预览');
    final req = await _open('GET', uri('/nodes/${n.id}/content'));
    try {
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode >= 400) throw _errorFrom(resp.statusCode, null);
      final b = BytesBuilder(copy: false);
      await for (final c in resp.timeout(const Duration(seconds: 60))) {
        b.add(c);
      }
      return b.takeBytes();
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// One Server-Sent-Events connection; completes when it drops.
  @override
  Stream<ServerEvent> events() async* {
    final req = await _open('GET', uri('/events'));
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(const Duration(seconds: 15));
    } catch (e) {
      throw _wrap(e);
    }
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw _errorFrom(resp.statusCode, null);
    }
    final lines =
        resp.timeout(const Duration(seconds: 70)).cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    try {
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final j = jsonDecode(line.substring(6));
        if (j is Map) yield ServerEvent.fromJson({...j.cast<String, dynamic>(), 'type': j['type'] ?? 'hello'});
      }
    } catch (e) {
      throw _wrap(e);
    }
  }
}
