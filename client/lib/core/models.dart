import 'package:flutter/material.dart';

DateTime _ms(dynamic v) => DateTime.fromMillisecondsSinceEpoch((v as num?)?.toInt() ?? 0);

class Node {
  Node({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isDir,
    required this.size,
    required this.mime,
    required this.sha256,
    required this.categoryId,
    required this.timeline,
    required this.deviceId,
    required this.deviceName,
    required this.mtime,
    required this.createdAt,
    required this.updatedAt,
    required this.childCount,
    required this.trashedAt,
    required this.location,
  });

  final String id;
  final String parentId;
  final String name;
  final bool isDir;
  final int size;
  final String mime;
  final String sha256;
  final String categoryId;
  final bool timeline;
  final String deviceId;
  final String deviceName;
  final DateTime mtime;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int childCount;
  final DateTime? trashedAt;
  final String location;

  factory Node.fromJson(Map<String, dynamic> j) => Node(
        id: j['id'] as String,
        parentId: (j['parent_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        isDir: (j['is_dir'] as bool?) ?? false,
        size: (j['size'] as num?)?.toInt() ?? 0,
        mime: (j['mime'] as String?) ?? '',
        sha256: (j['sha256'] as String?) ?? '',
        categoryId: (j['category_id'] as String?) ?? '',
        timeline: (j['timeline'] as bool?) ?? false,
        deviceId: (j['device_id'] as String?) ?? '',
        deviceName: (j['device_name'] as String?) ?? '',
        mtime: _ms(j['mtime']),
        createdAt: _ms(j['created_at']),
        updatedAt: _ms(j['updated_at']),
        childCount: (j['child_count'] as num?)?.toInt() ?? 0,
        trashedAt: j['trashed_at'] == null ? null : _ms(j['trashed_at']),
        location: (j['location'] as String?) ?? '',
      );

  Node copyWith({String? name, String? parentId, String? categoryId}) => Node(
        id: id,
        parentId: parentId ?? this.parentId,
        name: name ?? this.name,
        isDir: isDir,
        size: size,
        mime: mime,
        sha256: sha256,
        categoryId: categoryId ?? this.categoryId,
        timeline: timeline,
        deviceId: deviceId,
        deviceName: deviceName,
        mtime: mtime,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        childCount: childCount,
        trashedAt: trashedAt,
        location: location,
      );

  Node withLocation(String loc) => Node(
        id: id,
        parentId: parentId,
        name: name,
        isDir: isDir,
        size: size,
        mime: mime,
        sha256: sha256,
        categoryId: categoryId,
        timeline: timeline,
        deviceId: deviceId,
        deviceName: deviceName,
        mtime: mtime,
        createdAt: createdAt,
        updatedAt: updatedAt,
        childCount: childCount,
        trashedAt: trashedAt,
        location: loc,
      );

  String get ext {
    final i = name.lastIndexOf('.');
    return (i <= 0 || isDir) ? '' : name.substring(i + 1).toLowerCase();
  }

  bool get isImage => const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(ext);
  bool get isText =>
      mime.startsWith('text/') ||
      const {'md', 'json', 'yaml', 'yml', 'log', 'csv', 'xml', 'ini', 'conf', 'sh', 'py', 'go', 'dart', 'js', 'ts'}
          .contains(ext);
}

class Crumb {
  Crumb(this.id, this.name);
  final String id;
  final String name;
  factory Crumb.fromJson(Map<String, dynamic> j) => Crumb(j['id'] as String, (j['name'] as String?) ?? '');
}

class Listing {
  Listing(this.parent, this.path, this.children);
  final Node parent;
  final List<Crumb> path;
  final List<Node> children;
}

class WalkEntry {
  WalkEntry(this.node, this.relPath);
  final Node node;
  final String relPath;
}

class Category {
  Category({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.sort,
    required this.folderId,
    required this.count,
  });

  final String id;
  final String name;
  final Color color;
  final String icon;
  final int sort;
  final String folderId;
  final int count;

  String get hex => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static Color parseColor(String? s) {
    if (s == null || s.length != 7 || !s.startsWith('#')) return const Color(0xFF4F7CFF);
    final v = int.tryParse(s.substring(1), radix: 16);
    return v == null ? const Color(0xFF4F7CFF) : Color(0xFF000000 | v);
  }

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        color: parseColor(j['color'] as String?),
        icon: (j['icon'] as String?) ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        folderId: (j['folder_id'] as String?) ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toPanelJson() => {'id': id, 'name': name, 'color': hex, 'icon': icon};
}

class User {
  User(this.id, this.username, this.isAdmin, this.rootId, this.createdAt);
  final String id;
  final String username;
  final bool isAdmin;
  final String rootId;
  final DateTime createdAt;
  factory User.fromJson(Map<String, dynamic> j) => User(j['id'] as String, j['username'] as String,
      (j['is_admin'] as bool?) ?? false, (j['root_id'] as String?) ?? '', _ms(j['created_at']));
}

class Device {
  Device(this.id, this.name, this.platform, this.createdAt, this.lastSeenAt, this.lastIp,
      {this.relay = false, this.remote = false});
  final String id;
  final String name;
  final String platform;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final String lastIp;
  final bool relay; // can connect through the relay
  final bool remote; // relay only (added with a pairing code)
  factory Device.fromJson(Map<String, dynamic> j) => Device(j['id'] as String, (j['name'] as String?) ?? '',
      (j['platform'] as String?) ?? '', _ms(j['created_at']), _ms(j['last_seen_at']), (j['last_ip'] as String?) ?? '',
      relay: (j['relay'] as bool?) ?? false, remote: (j['remote'] as bool?) ?? false);
}

class AuditEntry {
  AuditEntry(this.action, this.detail, this.ip, this.at);
  final String action;
  final String detail;
  final String ip;
  final DateTime at;
  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
      j['action'] as String, (j['detail'] as String?) ?? '', (j['ip'] as String?) ?? '', _ms(j['at']));
}

class ServerInfo {
  ServerInfo(this.name, this.version, this.encryptedAtRest, this.chunkSize, this.maxFileSize, {this.relayUrl = ''});
  final String name;
  final String version;
  final bool encryptedAtRest;
  final int chunkSize;
  final int maxFileSize;
  final String relayUrl; // set when the NAS is linked to a relay
  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        (j['name'] as String?) ?? 'FileSwitch',
        (j['version'] as String?) ?? '',
        (j['encrypted_at_rest'] as bool?) ?? false,
        (j['chunk_size'] as num?)?.toInt() ?? (8 << 20),
        (j['max_file_size'] as num?)?.toInt() ?? 0,
        relayUrl: ((j['relay'] as Map?)?['url'] as String?) ?? '',
      );
}

class Stats {
  Stats(this.files, this.folders, this.bytes, this.trashBytes, this.diskFree, this.diskTotal);
  final int files;
  final int folders;
  final int bytes;
  final int trashBytes;
  final int diskFree;
  final int diskTotal;
  factory Stats.fromJson(Map<String, dynamic> j) {
    final s = (j['stats'] as Map).cast<String, dynamic>();
    int n(dynamic v) => (v as num?)?.toInt() ?? 0;
    return Stats(n(s['files']), n(s['folders']), n(s['bytes']), n(s['trash_bytes']), n(j['disk_free']),
        n(j['disk_total']));
  }
}

/// A server the user has connected to. The token itself lives in secure storage.
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.url,
    required this.name,
    this.username = '',
    this.fingerprint,
    this.deviceName = '',
    this.lastUsed,
    this.relayUrl = '',
  });

  final String id;

  /// Direct (LAN) address of the NAS; empty for devices added with a pairing code.
  String url;

  /// Relay address when this device is enrolled for access from outside.
  String relayUrl;
  String name;
  String username;

  /// SHA-256 of the pinned self-signed certificate. null = the certificate is
  /// trusted by the operating system (e.g. Let's Encrypt behind a reverse proxy).
  String? fingerprint;
  String deviceName;
  DateTime? lastUsed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'username': username,
        'fingerprint': fingerprint,
        'device_name': deviceName,
        'last_used': lastUsed?.millisecondsSinceEpoch,
        'relay_url': relayUrl,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'] as String,
        url: j['url'] as String,
        name: (j['name'] as String?) ?? '',
        username: (j['username'] as String?) ?? '',
        fingerprint: j['fingerprint'] as String?,
        deviceName: (j['device_name'] as String?) ?? '',
        lastUsed: j['last_used'] == null ? null : _ms(j['last_used']),
        relayUrl: (j['relay_url'] as String?) ?? '',
      );
}

class ServerEvent {
  ServerEvent(this.type, this.node, this.parentId, this.oldParentId, this.deviceId, this.target);
  final String type;
  final Node? node;
  final String parentId;
  final String oldParentId;
  final String deviceId;
  final String target;

  factory ServerEvent.fromJson(Map<String, dynamic> j) => ServerEvent(
        j['type'] as String,
        j['node'] == null ? null : Node.fromJson((j['node'] as Map).cast<String, dynamic>()),
        (j['parent_id'] as String?) ?? '',
        (j['old_parent_id'] as String?) ?? '',
        (j['device_id'] as String?) ?? '',
        (j['target'] as String?) ?? '',
      );
}
