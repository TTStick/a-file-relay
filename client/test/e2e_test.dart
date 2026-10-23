import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as h;
import 'package:fileswitch/core/e2e.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Interop with the Go implementation (vectors from server/internal/e2e).
void main() {
  final v = jsonDecode(File('test/e2e_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final sk = unhex(v['space_key']);
  final dk = unhex(v['device_key']);
  final content = unhex(v['content_hex']);

  test('opens Go envelopes, snapshots, blobs; derives the same keys', () async {
    final p = await openEnvelope(dk, v['envelope'] as Map, opAAD(v['device'], v['op']));
    expect(utf8.decode(p), '{"t":"ping"}');
    await expectLater(openEnvelope(dk, v['envelope'] as Map, replyAAD(v['device'], v['op'])), throwsA(isA<E2EAuthError>()));

    final (ver, snap) = await openSnapshot(base64.decode(v['snapshot']), v['space'], {5: sk});
    expect(ver, 77);
    expect(snap['hello'], '世界');
    await expectLater(openSnapshot(base64.decode(v['snapshot']), 'otherspace', {5: sk}), throwsA(isA<E2EAuthError>()));

    final (lookup, key) = await pairing(unhex(v['pair_secret']));
    expect(lookup, v['pair_lookup']);
    expect(hex(key), v['pair_key']);
    expect(cacheKey(sk, 'nodeid', 'abc'), v['cache_key']);
    expect(cipherSize(content.length), v['cipher_size']);

    final dir = await Directory.systemTemp.createTemp('e2e');
    final src = File('${dir.path}/blob')..writeAsBytesSync(base64.decode(v['blob']));
    final dst = '${dir.path}/out';
    await decryptFile(src.path, dst, content.length, {5: sk}, h.sha256.convert(content).toString());
    expect(File(dst).readAsBytesSync(), content);
    // wrong checksum → rejected
    await expectLater(decryptFile(src.path, dst, content.length, {5: sk}, '00'), throwsA(isA<E2EAuthError>()));
    // tampered → rejected
    final bad = base64.decode(v['blob']);
    bad[bad.length - 5] ^= 1;
    src.writeAsBytesSync(bad);
    await expectLater(decryptFile(src.path, dst, content.length, {5: sk}, ''), throwsA(isA<E2EAuthError>()));
    await dir.delete(recursive: true);
  });

  test('produces ciphertext Go can open; ranges are resumable', () async {
    final dir = await Directory.systemTemp.createTemp('e2e');
    final f = File('${dir.path}/plain')..writeAsBytesSync(content);
    final enc = await BlobEncryptor.create(f.path, content.length, 5, sk);
    final whole = await enc.range(0, enc.length);
    expect(whole.length, cipherSize(content.length));
    // resuming at odd offsets must give the exact same bytes
    final pieces = [...await enc.range(0, 50), ...await enc.range(50, 40000), ...await enc.range(40000, enc.length)];
    expect(pieces, whole);
    final env = await sealEnvelope(dk, utf8.encode('from dart'), replyAAD('dev', 'op'));
    File('${Directory.systemTemp.path}/fs_dart_vectors.json').writeAsStringSync(jsonEncode({
      'space_key': v['space_key'],
      'device_key': v['device_key'],
      'size': content.length,
      'content_hex': v['content_hex'],
      'blob': base64.encode(whole),
      'envelope': env,
    }));
    await dir.delete(recursive: true);
  });
}
