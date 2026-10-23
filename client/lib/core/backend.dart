import 'dart:io';
import 'dart:typed_data';

import 'api.dart';
import 'models.dart';

/// What the UI talks to. Two implementations: [ApiClient] (direct HTTPS to
/// the NAS on the LAN) and RelayBackend (end-to-end encrypted, through the
/// public relay, with the NAS collecting work on its own schedule).
abstract class Backend {
  /// True when going through the relay.
  bool get isRemote;

  /// Short label for the connection ("局域网直连" / "经中转站").
  String get modeLabel;

  void close();

  Future<(User, Device)> me();
  Future<ServerInfo> info();
  Future<void> logout();
  Future<void> changePassword(String oldPw, String newPw, {bool signOutOthers = false});
  Future<(List<Device>, String)> devices();
  Future<void> renameDevice(String id, String name);
  Future<void> revokeDevice(String id);
  Future<List<AuditEntry>> audit();
  Future<Stats> stats();

  Future<List<User>> users();
  Future<void> createUser(String username, String password, bool admin);
  Future<void> deleteUser(String id);
  Future<void> resetPassword(String id, String password);

  Future<List<Category>> categories();
  Future<Category> createCategory(String name, String color, String icon);
  Future<Category> updateCategory(String id, {String? name, String? color, String? icon, String? folderId});
  Future<void> deleteCategory(String id);
  Future<void> reorderCategories(List<String> ids);

  Future<Listing> list(String? parentId, {bool dirsOnly = false});
  Future<(Node, List<Crumb>)> node(String id);
  Future<Node> createFolder({
    String? parentId,
    String? categoryId,
    String? name,
    String? path,
    String conflict = 'fail',
    bool timeline = false,
    int? mtime,
  });
  Future<Node> patchNode(String id, {String? name, String? parentId, String? categoryId, bool? timeline});
  Future<void> trash(String id);
  Future<Map<String, String>> batch(String action, List<String> ids, {String? parentId, String? categoryId});
  Future<List<WalkEntry>> walk(String id);
  Future<(List<Node>, bool)> timeline({DateTime? before, int limit = 100, String? category});
  Future<(List<Node>, bool)> tagged(String categoryId, {DateTime? before, int limit = 100});
  Future<List<Node>> search(String q);
  Future<List<Node>> trashList();
  Future<Node> restore(String id);
  Future<void> purge(String id);
  Future<void> emptyTrash();

  Future<Uint8List> bytes(Node n, {int maxBytes = 32 << 20});
  Future<void> download(Node n, File target,
      {void Function(int got)? onProgress, CancelToken? cancel, void Function(String? phase)? onPhase});

  /// One live event connection; completes or throws when it drops.
  Stream<ServerEvent> events();

  /// A one-time code that adds a new device through the relay.
  Future<(String, DateTime)> createPairingCode();

  /// Remote devices may be barred by NAS policy from deleting permanently.
  bool get canPurge;
}
