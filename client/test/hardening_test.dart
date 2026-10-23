import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as h;
import 'package:fileswitch/core/api.dart';
import 'package:fileswitch/core/e2e.dart';
import 'package:fileswitch/core/transfers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  test('names from the server cannot climb out of the download folder', () {
    expect(safeName('..'), '_');
    expect(safeName('.'), '_');
    expect(safeName('../x'), '.._x');
    const root = '/Users/me/Downloads/项目';
    final joined = p.joinAll([root, ...'项目/../../.ssh/authorized_keys'.split('/').skip(1).map(safeName)]);
    expect(p.isWithin(root, p.normalize(joined)), isTrue);
  });

  test('only https server addresses are accepted', () {
    expect(() => normalizeServerUrl('http://192.168.1.5:8443'), throwsFormatException);
    expect(normalizeServerUrl('192.168.1.5').toString(), 'https://192.168.1.5:8443');
  });

  test('snapshot inflation is capped', () {
    final small = gzip.encode(utf8.encode('{"a":1}'));
    expect(utf8.decode(gunzipLimited(small, 1 << 20)), '{"a":1}');
    final bomb = gzip.encode(List.filled(8 << 20, 0));
    expect(bomb.length, lessThan(64 << 10));
    expect(() => gunzipLimited(bomb, 1 << 20), throwsA(isA<E2EAuthError>()));
  });

  test('a failed decrypt leaves no plaintext behind', () async {
    final v = jsonDecode(File('test/e2e_vectors.json').readAsStringSync()) as Map<String, dynamic>;
    final content = unhex(v['content_hex']);
    final dir = Directory.systemTemp.createTempSync('fs-hardening');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = File('${dir.path}/blob')..writeAsBytesSync(base64.decode(v['blob']));
    final dst = '${dir.path}/out';
    final sk = unhex(v['space_key']);
    await expectLater(decryptFile(src.path, dst, content.length, {5: sk}, '00'), throwsA(isA<E2EAuthError>()));
    expect(File(dst).existsSync(), isFalse);
    await decryptFile(src.path, dst, content.length, {5: sk}, h.sha256.convert(content).toString());
    expect(File(dst).readAsBytesSync(), content);
  });

  group('certificate pinning', () {
    HttpServer? server;
    late String fp;

    setUpAll(() async {
      final dir = Directory.systemTemp.createTempSync('fs-pin');
      final r = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', '${dir.path}/k.pem', '-out', '${dir.path}/c.pem',
      ]);
      if (r.exitCode != 0) fail('openssl: ${r.stderr}');
      final ctx = SecurityContext()
        ..useCertificateChain('${dir.path}/c.pem')
        ..usePrivateKey('${dir.path}/k.pem');
      server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
      server!.listen((req) => req.response
        ..write('ok')
        ..close());
      final der = await Process.run('openssl', ['x509', '-in', '${dir.path}/c.pem', '-outform', 'DER'], stdoutEncoding: null);
      fp = h.sha256.convert(der.stdout as List<int>).bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
    });

    tearDownAll(() => server?.close(force: true));

    Future<String> get(String? pin) async {
      final c = pinnedHttpClient(pin);
      try {
        final resp = await (await c.getUrl(Uri.parse('https://127.0.0.1:${server!.port}/'))).close();
        return await utf8.decodeStream(resp);
      } finally {
        c.close(force: true);
      }
    }

    test('the pinned certificate is accepted', () async {
      expect(await get(fp), 'ok');
      expect(await get(fp.replaceAll(':', '').toLowerCase()), 'ok');
    });

    test('any other certificate is refused', () async {
      await expectLater(get('00:${fp.substring(3)}'), throwsA(isA<HandshakeException>()));
      await expectLater(get(null), throwsA(isA<HandshakeException>()));
    });
  });
}
