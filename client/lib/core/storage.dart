import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class AppConfig {
  List<ServerProfile> profiles = [];
  String? activeId;
  String? downloadDir;
  bool notifyIncoming = true;
  bool startHidden = false;

  Map<String, dynamic> toJson() => {
        'profiles': profiles.map((e) => e.toJson()).toList(),
        'active_id': activeId,
        'download_dir': downloadDir,
        'notify_incoming': notifyIncoming,
        'start_hidden': startHidden,
      };

  static AppConfig fromJson(Map<String, dynamic> j) => AppConfig()
    ..profiles = ((j['profiles'] as List?) ?? [])
        .map((e) => ServerProfile.fromJson((e as Map).cast<String, dynamic>()))
        .toList()
    ..activeId = j['active_id'] as String?
    ..downloadDir = j['download_dir'] as String?
    ..notifyIncoming = (j['notify_incoming'] as bool?) ?? true
    ..startHidden = (j['start_hidden'] as bool?) ?? false;
}

/// Non-secret settings go to a JSON file; device tokens go to the OS keychain
/// (Keychain / Android Keystore / Windows Credential Manager).
class Storage {
  static const _secure = FlutterSecureStorage(
    // The legacy file keychain works without a signing team / entitlements.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'config.json'));
  }

  static Future<AppConfig> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return AppConfig();
      return AppConfig.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return AppConfig();
    }
  }

  static Future<void> save(AppConfig c) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(c.toJson()));
    await tmp.rename(f.path);
  }

  static Future<String?> token(String profileId) async {
    try {
      return await _secure.read(key: 'token_$profileId');
    } catch (_) {
      return null;
    }
  }

  /// Relay credentials (device key, relay token, keyring) as JSON.
  static Future<Map<String, dynamic>?> relay(String profileId) async {
    try {
      final s = await _secure.read(key: 'relay_$profileId');
      return s == null ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static Future<void> setRelay(String profileId, Map<String, dynamic>? creds) async {
    if (creds == null) {
      await _secure.delete(key: 'relay_$profileId');
    } else {
      await _secure.write(key: 'relay_$profileId', value: jsonEncode(creds));
    }
  }

  static Future<void> setToken(String profileId, String? token) async {
    if (token == null) {
      await _secure.delete(key: 'token_$profileId');
    } else {
      await _secure.write(key: 'token_$profileId', value: token);
    }
  }
}
