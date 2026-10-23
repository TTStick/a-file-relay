// End-to-end encryption for relay mode — the Dart twin of server/internal/e2e.
// The relay only ever sees what this file produces. Bulk work (file
// segments, snapshots) runs in background isolates so the UI stays smooth.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as h;
import 'package:cryptography/cryptography.dart';

const keySize = 32;
const nonceSize = 24;
const tagSize = 16;
const segSize = 64 * 1024;
const headerSize = 4 + 4 + 4 + nonceSize + keySize + tagSize; // 84

class E2EAuthError implements Exception {
  @override
  String toString() => '数据校验失败（可能被篡改或密钥不匹配）';
}

final _rnd = Random.secure();
final _aead = Xchacha20.poly1305Aead();

Uint8List randomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _rnd.nextInt(256);
  }
  return b;
}

String randomHex(int bytes) => randomBytes(bytes).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<Uint8List> seal(List<int> key, List<int> nonce, List<int> plain, List<int> aad) async {
  final box = await _aead.encrypt(plain, secretKey: SecretKeyData(key), nonce: nonce, aad: aad);
  final out = Uint8List(box.cipherText.length + tagSize);
  out.setAll(0, box.cipherText);
  out.setAll(box.cipherText.length, box.mac.bytes);
  return out;
}

Future<Uint8List> open(List<int> key, List<int> nonce, List<int> ct, List<int> aad) async {
  if (ct.length < tagSize || key.length != keySize || nonce.length != nonceSize) throw E2EAuthError();
  try {
    final box = SecretBox(ct.sublist(0, ct.length - tagSize), nonce: nonce, mac: Mac(ct.sublist(ct.length - tagSize)));
    final p = await _aead.decrypt(box, secretKey: SecretKeyData(key), aad: aad);
    return p is Uint8List ? p : Uint8List.fromList(p);
  } on SecretBoxAuthenticationError {
    throw E2EAuthError();
  }
}

// --- envelopes (ops, replies, keyrings, pairing) ---

String opAAD(String device, String op) => 'fsop1|$device|$op';
String replyAAD(String device, String op) => 'fsrp1|$device|$op';
String keyringAAD(String device) => 'fskr1|$device';
String pairReqAAD(String lookup) => 'fspq1|$lookup';
String pairRespAAD(String lookup) => 'fsps1|$lookup';

Future<Map<String, String>> sealEnvelope(List<int> key, List<int> plain, String aad) async {
  final n = randomBytes(nonceSize);
  final c = await seal(key, n, plain, utf8.encode(aad));
  return {'n': base64.encode(n), 'c': base64.encode(c)};
}

Future<Uint8List> openEnvelope(List<int> key, Map env, String aad) async {
  try {
    return await open(key, base64.decode(env['n'] as String), base64.decode(env['c'] as String), utf8.encode(aad));
  } on FormatException {
    throw E2EAuthError();
  } on TypeError {
    throw E2EAuthError();
  }
}

// --- keys ---

/// Space keys by key id.
typedef Keyring = Map<int, Uint8List>;

Keyring keyringFromJson(Map j) => {
      for (final e in ((j['keys'] as Map?) ?? {}).entries)
        int.parse(e.key as String): Uint8List.fromList(base64.decode(e.value as String)),
    };

Map<String, dynamic> keyringToJson(Keyring k, int current) => {
      'current': current,
      'keys': {for (final e in k.entries) '${e.key}': base64.encode(e.value)},
    };

/// Derives the relay lookup id and envelope key from a pairing secret.
Future<(String, Uint8List)> pairing(List<int> secret) async {
  Future<List<int>> derive(String info, int len) async {
    final k = await Hkdf(hmac: Hmac.sha256(), outputLength: len)
        .deriveKey(secretKey: SecretKeyData(secret), nonce: utf8.encode('fileswitch-pair'), info: utf8.encode(info));
    return k.bytes;
  }

  final lookup = (await derive('lookup', 16)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return (lookup, Uint8List.fromList(await derive('key', keySize)));
}

String cacheKey(List<int> spaceKey, String nodeId, String sha) {
  final mac = h.Hmac(h.sha256, spaceKey).convert(utf8.encode('cache|$nodeId|$sha')).bytes;
  return mac.sublist(0, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// --- blobs ---

int cipherSize(int size) => headerSize + size + max(1, (size + segSize - 1) ~/ segSize) * tagSize;

Uint8List _segNonce(int i) {
  final n = Uint8List(nonceSize);
  ByteData.sublistView(n).setUint64(16, i);
  return n;
}

Uint8List _be32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// Encrypts one file for upload. Any byte range of the ciphertext can be
/// regenerated (segments are deterministic for a given file key), so uploads
/// resume from wherever the relay says it is.
class BlobEncryptor {
  BlobEncryptor._(this.path, this.size, this._fk, this.header);

  final String path;
  final int size;
  final Uint8List _fk;
  final Uint8List header;

  static Future<BlobEncryptor> create(String path, int size, int kid, List<int> spaceKey) async {
    final fk = randomBytes(keySize);
    final nonce = randomBytes(nonceSize);
    final aad = Uint8List.fromList([...utf8.encode('FSE1'), ..._be32(kid)]);
    final wrapped = await seal(spaceKey, nonce, fk, aad);
    final hdr = Uint8List.fromList([...utf8.encode('FSE1'), 1, 0, 0, 0, ..._be32(kid), ...nonce, ...wrapped]);
    return BlobEncryptor._(path, size, fk, hdr);
  }

  int get length => cipherSize(size);
  String get nonceB64 => base64.encode(header.sublist(12, 12 + nonceSize));

  /// Ciphertext bytes [start, end), computed in a background isolate.
  Future<Uint8List> range(int start, int end) {
    if (start < 0 || end > length || start > end) throw RangeError('bad ciphertext range $start-$end of $length');
    final path = this.path, size = this.size, fk = _fk, hdr = header;
    return Isolate.run(() => _encryptRange(path, size, fk, hdr, start, end));
  }
}

Future<Uint8List> _encryptRange(String path, int size, Uint8List fk, Uint8List hdr, int start, int end) async {
  final out = BytesBuilder(copy: false);
  var pos = start;
  if (pos < headerSize) {
    out.add(hdr.sublist(pos, min(end, headerSize)));
    pos = headerSize;
  }
  if (pos >= end) return out.takeBytes();
  final nseg = max(1, (size + segSize - 1) ~/ segSize);
  final raf = File(path).openSync();
  try {
    while (pos < end) {
      final i = (pos - headerSize) ~/ (segSize + tagSize);
      final segStart = headerSize + i * (segSize + tagSize);
      final plainLen = min(segSize, size - i * segSize);
      raf.setPositionSync(i * segSize);
      final plain = raf.readSync(plainLen);
      if (plain.length != plainLen) throw const FileSystemException('文件在上传过程中被修改');
      final ct = await seal(fk, _segNonce(i), plain, [i == nseg - 1 ? 1 : 0]);
      final to = min(ct.length, end - segStart);
      out.add(ct.sublist(pos - segStart, to));
      pos = segStart + to;
    }
  } finally {
    raf.closeSync();
  }
  return out.takeBytes();
}

/// Decrypts an FSE1 blob file into dst, verifying every segment and the
/// SHA-256 recorded by the NAS. Runs in a background isolate.
Future<void> decryptFile(String src, String dst, int size, Keyring ring, String sha) {
  return Isolate.run(() async {
    final inp = File(src).openSync();
    final out = File(dst).openSync(mode: FileMode.write);
    try {
      if (inp.lengthSync() != cipherSize(size)) throw E2EAuthError();
      final fk = await _unwrap(inp.readSync(headerSize), ring);
      final nseg = max(1, (size + segSize - 1) ~/ segSize);
      final digest = _Sink();
      final hasher = h.sha256.startChunkedConversion(digest);
      for (var i = 0; i < nseg; i++) {
        final len = min(segSize, size - i * segSize) + tagSize;
        final ct = inp.readSync(len);
        if (ct.length != len) throw E2EAuthError();
        final pt = await open(fk, _segNonce(i), ct, [i == nseg - 1 ? 1 : 0]);
        out.writeFromSync(pt);
        hasher.add(pt);
      }
      hasher.close();
      if (sha.isNotEmpty && digest.value.toString() != sha) throw E2EAuthError();
    } finally {
      inp.closeSync();
      out.closeSync();
    }
  });
}

class _Sink implements Sink<h.Digest> {
  late h.Digest value;
  @override
  void add(h.Digest data) => value = data;
  @override
  void close() {}
}

Future<Uint8List> _unwrap(List<int> hdr, Keyring ring) async {
  if (hdr.length != headerSize || utf8.decode(hdr.sublist(0, 4), allowMalformed: true) != 'FSE1' || hdr[4] != 1) {
    throw E2EAuthError();
  }
  final kid = ByteData.sublistView(Uint8List.fromList(hdr.sublist(8, 12))).getUint32(0);
  final sk = ring[kid];
  if (sk == null) throw E2EAuthError();
  return open(sk, hdr.sublist(12, 12 + nonceSize), hdr.sublist(12 + nonceSize), [...utf8.encode('FSE1'), ..._be32(kid)]);
}

// --- snapshots ---

/// Opens an FSS1 snapshot and returns (version, decoded JSON). Runs in an isolate.
Future<(int, Map<String, dynamic>)> openSnapshot(Uint8List data, String spaceId, Keyring ring) {
  return Isolate.run(() async {
    if (data.length < 16 + nonceSize || utf8.decode(data.sublist(0, 4), allowMalformed: true) != 'FSS1') {
      throw E2EAuthError();
    }
    final bd = ByteData.sublistView(data);
    final kid = bd.getUint32(4);
    final version = bd.getUint64(8);
    final sk = ring[kid];
    if (sk == null) throw E2EAuthError();
    final aad = Uint8List.fromList([...utf8.encode('FSS1'), ..._be32(kid), ...data.sublist(8, 16), ...utf8.encode(spaceId)]);
    final z = await open(sk, data.sublist(16, 16 + nonceSize), data.sublist(16 + nonceSize), aad);
    final j = jsonDecode(utf8.decode(gzip.decode(z))) as Map<String, dynamic>;
    return (version, j);
  });
}
