import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as h;
import 'package:fileswitch/core/relay_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pending uploads against a live relay (skipped unless a pairing code is given):
/// pairs as a new device, uploads a file without handing it to the NAS, then
/// downloads every pending upload it can open, including other apps' ones.
///
///   FS_PENDING_PAIR=fileswitch://pair?... FS_PENDING_OUT=/tmp/out.json flutter test test/pending_interop_test.dart
void main() {
  final code = Platform.environment['FS_PENDING_PAIR'];
  test('pending uploads from the relay', () async {
    final creds = await RelayBackend.pair(code!, 'Flutter 测试', 'android');
    final relay = RelayBackend(creds, onCredsChanged: (_) async {});
    final dir = Directory.systemTemp.createTempSync('fs-pending');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rnd = Random();
    final content = Uint8List.fromList(List.generate((2 << 20) + 777, (_) => rnd.nextInt(256)));
    final src = File('${dir.path}/安卓上传.bin')..writeAsBytesSync(content);
    final (blob, _) = await relay.uploadBlob(src, content.length, path: '临时/安卓上传.bin', from: 'Flutter 测试');

    final files = <Map<String, dynamic>>[];
    for (final p in await relay.pendingFiles()) {
      final dst = File('${dir.path}/dl-${p.id}');
      await relay.downloadPending(p, dst);
      final data = dst.readAsBytesSync();
      if (p.id == blob) expect(data, content);
      files.add({'id': p.id, 'name': p.name, 'path': p.path, 'from': p.from, 'size': data.length, 'sha256': h.sha256.convert(data).toString()});
    }
    expect(files.map((f) => f['id']), contains(blob));
    final out = Platform.environment['FS_PENDING_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(
          {'own': blob, 'own_sha256': h.sha256.convert(content).toString(), 'files': files}));
    }
    relay.close();
  }, skip: code == null ? 'needs FS_PENDING_PAIR' : null, timeout: const Timeout(Duration(minutes: 5)));
}
