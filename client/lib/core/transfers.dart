import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'app_state.dart';
import 'backend.dart';
import 'models.dart';
import 'relay_backend.dart';

enum TransferKind { upload, download }

enum TransferStatus { queued, running, done, failed, canceled }

class Transfer {
  Transfer(this.kind, this.name, {this.isFolder = false, this.destination = ''});

  static int _seq = 0;
  final int id = ++_seq;
  final TransferKind kind;
  final String name;
  final bool isFolder;
  final String destination; // human readable target ("照片", "/工作/资料", local dir)
  final DateTime created = DateTime.now();
  final cancel = CancelToken();
  final _done = Completer<void>();

  /// Completes when the transfer finishes, fails or is canceled.
  Future<void> get finished => _done.future;

  TransferStatus status = TransferStatus.queued;
  String? error;
  String? phase; // e.g. "扫描文件…"
  int totalBytes = 0;
  int doneBytes = 0;
  int totalFiles = 0;
  int doneFiles = 0;
  int failedFiles = 0;
  String? localPath; // downloads: where it landed
  Node? node; // uploads: the created node

  // simple moving speed estimate
  DateTime _lastSample = DateTime.now();
  int _lastBytes = 0;
  double speed = 0;

  double get progress => totalBytes <= 0 ? (status == TransferStatus.done ? 1 : 0) : doneBytes / totalBytes;
  bool get active => status == TransferStatus.queued || status == TransferStatus.running;

  void _sample() {
    final now = DateTime.now();
    final dt = now.difference(_lastSample).inMilliseconds;
    if (dt >= 500) {
      final inst = (doneBytes - _lastBytes) * 1000 / dt;
      speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4;
      _lastSample = now;
      _lastBytes = doneBytes;
    }
  }
}

/// Limits how many file transfers run at once across all queued items.
class _Pool {
  _Pool(this.size);
  final int size;
  int _running = 0;
  final _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() fn) async {
    if (_running >= size) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _running++;
    try {
      return await fn();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
    }
  }
}

const _junk = {'.DS_Store', 'Thumbs.db', 'desktop.ini', '.localized', 'Icon\r'};

class TransferManager extends ChangeNotifier {
  TransferManager._();
  static final TransferManager instance = TransferManager._();

  final List<Transfer> items = [];
  final _pool = _Pool(3);
  Timer? _tick;

  Backend get _api {
    final a = AppState.instance.api;
    if (a == null) throw ApiException(401, 'unauthorized', '未登录');
    return a;
  }

  int get activeCount => items.where((t) => t.active).length;

  /// Overall upload progress (0-1) over active uploads, or null when idle.
  double? get uploadProgress {
    final ups = items.where((t) => t.kind == TransferKind.upload && t.active).toList();
    if (ups.isEmpty) return null;
    final total = ups.fold<int>(0, (s, t) => s + t.totalBytes);
    final done = ups.fold<int>(0, (s, t) => s + t.doneBytes);
    return total == 0 ? 0 : done / total;
  }

  void _changed() {
    // Progress callbacks fire per network chunk; coalesce repaints.
    _tick ??= Timer(const Duration(milliseconds: 150), () {
      _tick = null;
      for (final t in items) {
        if (t.status == TransferStatus.running) t._sample();
      }
      notifyListeners();
    });
  }

  void clearFinished() {
    items.removeWhere((t) => !t.active);
    notifyListeners();
  }

  void remove(Transfer t) {
    if (t.active) t.cancel.cancel();
    items.remove(t);
    notifyListeners();
  }

  void cancel(Transfer t) {
    t.cancel.cancel();
    if (t.status == TransferStatus.queued) t.status = TransferStatus.canceled;
    notifyListeners();
  }

  Transfer _add(Transfer t) {
    items.insert(0, t);
    if (items.length > 200) items.removeWhere((x) => !x.active && items.indexOf(x) > 150);
    notifyListeners();
    return t;
  }

  void _finish(Transfer t, [Object? error]) {
    if (error is CanceledException || t.cancel.isCanceled) {
      t.status = TransferStatus.canceled;
    } else if (error != null) {
      t.status = TransferStatus.failed;
      t.error = error.toString();
    } else if (t.failedFiles > 0) {
      t.status = TransferStatus.failed;
      t.error ??= '${t.failedFiles} 个文件失败';
    } else {
      t.status = TransferStatus.done;
      t.doneBytes = t.totalBytes;
    }
    t.phase = null;
    if (!t._done.isCompleted) t._done.complete();
    notifyListeners();
  }

  // --- uploads ---

  /// Uploads local files and folders. Destination is a folder ([parentId]) or
  /// a category ([categoryId], which goes to the category's folder).
  List<Transfer> upload(List<String> paths, {String? parentId, String? categoryId, String destination = ''}) {
    final out = <Transfer>[];
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path, followLinks: true);
      if (type == FileSystemEntityType.directory) {
        out.add(_uploadFolder(Directory(path), parentId, categoryId, destination));
      } else if (type == FileSystemEntityType.file) {
        out.add(_uploadOne(File(path), parentId, categoryId, destination));
      }
    }
    return out;
  }

  Transfer _uploadOne(File f, String? parentId, String? categoryId, String destination) {
    final t = _add(Transfer(TransferKind.upload, p.basename(f.path), destination: destination));
    () async {
      try {
        t.totalBytes = await f.length();
        t.totalFiles = 1;
        final api = _api;
        await _pool.run(() async {
          t.cancel.check();
          t.status = TransferStatus.running;
          _changed();
          void progress(int sent) {
            t.doneBytes = sent;
            _changed();
          }

          if (api is RelayBackend) {
            final (blob, nonce) = await api.uploadBlob(f, t.totalBytes, cancel: t.cancel, onProgress: progress);
            t.phase = '等待 NAS 接收…';
            _changed();
            final r = await api.commitUpload({
              'parent_id': ?parentId,
              'category_id': ?categoryId,
              'files': [_entry(p.basename(f.path), blob, nonce, t.totalBytes, await f.lastModified())],
            });
            _checkCommit(r);
          } else if (api is ApiClient) {
            t.node = await api.uploadFile(f,
                parentId: parentId,
                categoryId: categoryId,
                relPath: p.basename(f.path),
                timeline: true,
                cancel: t.cancel,
                onProgress: progress);
          }
        });
        t.doneFiles = 1;
        _finish(t);
      } catch (e) {
        _finish(t, e);
      }
    }();
    return t;
  }

  Map<String, dynamic> _entry(String rel, String blob, String nonce, int size, DateTime mtime) =>
      {'rel': rel, 'blob': blob, 'nonce': nonce, 'size': size, 'mtime': mtime.millisecondsSinceEpoch};

  void _checkCommit(Map<String, dynamic> r) {
    final failed = (r['failed'] as Map?) ?? {};
    if (failed.isNotEmpty) throw ApiException(400, 'nas', '${failed.keys.first}: ${failed.values.first}');
  }

  Transfer _uploadFolder(Directory dir, String? parentId, String? categoryId, String destination) {
    final name = p.basename(dir.path);
    final t = _add(Transfer(TransferKind.upload, name, isFolder: true, destination: destination));
    () async {
      try {
        t.status = TransferStatus.running;
        t.phase = '正在扫描…';
        notifyListeners();
        final files = <File>[];
        final rels = <String>[];
        final dirs = <String>{};
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          t.cancel.check();
          final rel = p.split(p.relative(e.path, from: dir.path)).join('/');
          if (rel.split('/').any((c) => _junk.contains(c) || c.startsWith('._'))) continue;
          if (e is File) {
            files.add(e);
            rels.add(rel);
            t.totalBytes += await e.length();
          } else if (e is Directory) {
            dirs.add(rel);
          }
        }
        t.totalFiles = files.length;
        t.phase = null;
        _changed();

        final api = _api;
        if (api is RelayBackend) {
          await _uploadFolderRelay(api, t, dir, files, rels, dirs, parentId, categoryId);
          _finish(t);
          return;
        }
        final top = await api.createFolder(
          parentId: parentId,
          categoryId: categoryId,
          name: name,
          conflict: 'rename',
          timeline: true,
          mtime: (await dir.stat()).modified.millisecondsSinceEpoch,
        );
        t.node = top;

        // Folders holding files are created on upload; create the empty ones.
        final used = <String>{};
        for (final r in rels) {
          final parts = r.split('/');
          for (var i = 1; i < parts.length; i++) {
            used.add(parts.sublist(0, i).join('/'));
          }
        }
        for (final d in dirs.difference(used)) {
          if (!dirs.any((o) => o.startsWith('$d/'))) {
            t.cancel.check();
            await api.createFolder(parentId: top.id, path: d);
          }
        }

        final progress = List<int>.filled(files.length, 0);
        await Future.wait(List.generate(files.length, (i) async {
          try {
            await _pool.run(() async {
              t.cancel.check();
              await (api as ApiClient).uploadFile(files[i],
                  parentId: top.id, relPath: rels[i], conflict: 'rename', cancel: t.cancel, onProgress: (sent) {
                t.doneBytes += sent - progress[i];
                progress[i] = sent;
                _changed();
              });
            });
            t.doneFiles++;
          } on CanceledException {
            rethrow;
          } catch (e) {
            t.failedFiles++;
            t.error = '${rels[i]}: $e';
          }
          _changed();
        }));
        _finish(t);
      } catch (e) {
        _finish(t, e);
      }
    }();
    return t;
  }

  /// Relay mode: encrypt and upload the files, then ask the NAS to take them
  /// in batches (the first batch also creates the folder and empty dirs), so
  /// the relay never has to hold more than one batch.
  Future<void> _uploadFolderRelay(RelayBackend api, Transfer t, Directory dir, List<File> files, List<String> rels,
      Set<String> dirs, String? parentId, String? categoryId) async {
    final used = <String>{};
    for (final r in rels) {
      final parts = r.split('/');
      for (var i = 1; i < parts.length; i++) {
        used.add(parts.sublist(0, i).join('/'));
      }
    }
    final emptyDirs = [for (final d in dirs.difference(used)) if (!dirs.any((o) => o.startsWith('$d/'))) d];
    final progress = List<int>.filled(files.length, 0);
    String? folderId;
    var start = 0;
    do {
      var end = start, bytes = 0;
      while (end < files.length && end - start < 500 && (bytes < (2 << 30) || end == start)) {
        bytes += await files[end].length();
        end++;
      }
      final entries = <Map<String, dynamic>>[];
      await Future.wait(List.generate(end - start, (k) async {
        final i = start + k;
        try {
          await _pool.run(() async {
            t.cancel.check();
            final size = await files[i].length();
            final (blob, nonce) = await api.uploadBlob(files[i], size, cancel: t.cancel, onProgress: (sent) {
              t.doneBytes += sent - progress[i];
              progress[i] = sent;
              _changed();
            });
            entries.add(_entry(rels[i], blob, nonce, size, await files[i].lastModified()));
          });
        } on CanceledException {
          rethrow;
        } catch (e) {
          t.failedFiles++;
          t.error = '${rels[i]}: $e';
        }
      }));
      t.phase = '等待 NAS 接收…';
      _changed();
      final r = await api.commitUpload(folderId == null
          ? {
              'parent_id': ?parentId,
              'category_id': ?categoryId,
              'folder': {'name': p.basename(dir.path), 'mtime': (await dir.stat()).modified.millisecondsSinceEpoch},
              'dirs': emptyDirs,
              'files': entries,
            }
          : {'parent_id': folderId, 'nested': true, 'files': entries});
      folderId ??= r['folder_id'] as String?;
      final failed = (r['failed'] as Map?) ?? {};
      t.doneFiles += (r['created'] as num?)?.toInt() ?? 0;
      if (failed.isNotEmpty) {
        t.failedFiles += failed.length;
        t.error = '${failed.keys.first}: ${failed.values.first}';
      }
      t.phase = null;
      _changed();
      start = end;
    } while (start < files.length);
  }

  // --- downloads ---

  Future<String> defaultDownloadDir() async {
    final configured = AppState.instance.config.downloadDir;
    if (configured != null && configured.isNotEmpty) return configured;
    if (isDesktop) {
      final d = await getDownloadsDirectory();
      if (d != null) return p.join(d.path, 'FileSwitch');
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Downloads');
  }

  /// Downloads a file or folder into [toDir] (default download directory).
  Transfer download(Node n, {String? toDir}) {
    final t = _add(Transfer(TransferKind.download, n.name, isFolder: n.isDir));
    () async {
      try {
        final dir = toDir ?? await defaultDownloadDir();
        await Directory(dir).create(recursive: true);
        t.status = TransferStatus.running;
        if (!n.isDir) {
          t.totalBytes = n.size;
          t.totalFiles = 1;
          final target = await _uniquePath(p.join(dir, safeName(n.name)));
          t.localPath = target;
          await _pool.run(() async {
            t.cancel.check();
            await _api.download(n, File(target), cancel: t.cancel, onPhase: (ph) {
              t.phase = ph;
              _changed();
            }, onProgress: (got) {
              t.doneBytes = got;
              _changed();
            });
          });
          t.doneFiles = 1;
        } else {
          t.phase = '正在读取目录…';
          notifyListeners();
          final entries = await _api.walk(n.id);
          final root = await _uniquePath(p.join(dir, safeName(n.name)));
          t.localPath = root;
          t.phase = null;
          final files = entries.where((e) => !e.node.isDir).toList();
          t.totalFiles = files.length;
          t.totalBytes = files.fold(0, (s, e) => s + e.node.size);
          String local(WalkEntry e) {
            final parts = e.relPath.split('/').skip(1).map(safeName).toList();
            final path = parts.isEmpty ? root : p.joinAll([root, ...parts]);
            // safeName already rules this out; a second check costs nothing
            if (path != root && !p.isWithin(root, p.normalize(path))) {
              throw ApiException(0, 'bad_path', '服务器返回了无效的路径：${e.relPath}');
            }
            return path;
          }

          for (final e in entries.where((e) => e.node.isDir)) {
            await Directory(local(e)).create(recursive: true);
          }
          final api = _api;
          if (api is RelayBackend) await api.prefetch(files.map((e) => e.node).toList());
          final progress = List<int>.filled(files.length, 0);
          await Future.wait(List.generate(files.length, (i) async {
            try {
              await _pool.run(() async {
                t.cancel.check();
                await _api.download(files[i].node, File(local(files[i])), cancel: t.cancel, onPhase: (ph) {
                  t.phase = ph;
                  _changed();
                }, onProgress: (got) {
                  t.doneBytes += got - progress[i];
                  progress[i] = got;
                  _changed();
                });
              });
              t.doneFiles++;
            } on CanceledException {
              rethrow;
            } catch (e) {
              t.failedFiles++;
              t.error = '${files[i].relPath}: $e';
            }
            _changed();
          }));
        }
        _finish(t);
      } catch (e) {
        _finish(t, e);
      }
    }();
    return t;
  }

  /// Downloads a file into the cache (for "open"), reusing an earlier copy.
  Future<String> fetchToCache(Node n) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'fileswitch-open', n.id));
    final target = File(p.join(dir.path, safeName(n.name)));
    if (await target.exists() && await target.length() == n.size) return target.path;
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final t = download(n, toDir: dir.path);
    await t.finished;
    if (t.status != TransferStatus.done) throw ApiException(0, 'failed', t.error ?? '已取消');
    return t.localPath!;
  }

  static Future<String> _uniquePath(String path) async {
    if (!await FileSystemEntity.isDirectory(path) && !await File(path).exists()) return path;
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final base = p.basenameWithoutExtension(path);
    for (var i = 1;; i++) {
      final cand = p.join(dir, '$base ($i)$ext');
      if (!await FileSystemEntity.isDirectory(cand) && !await File(cand).exists()) return cand;
    }
  }
}

/// Makes a server-side name safe to use as one path component on this
/// machine. The server never sends "." or "..", but a download must not be
/// able to leave its folder even if it did.
String safeName(String name) {
  if (name == '.' || name == '..') return '_';
  var s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  if (Platform.isWindows) {
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    const reserved = {'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3'};
    if (reserved.contains(s.split('.').first.toUpperCase())) s = '_$s';
  }
  return s.isEmpty ? '_' : s;
}
