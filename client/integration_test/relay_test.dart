// End-to-end test of relay mode: the app pairs with a code and then works only
// through the relay, while the NAS collects work on its own schedule.
//
//   docker exec <nas> fileswitch pair admin          # prints the code
//   flutter test integration_test/relay_test.dart -d macos \
//     --dart-define=FS_PAIR_CODE='fileswitch://pair?...' --dart-define=FS_SHOTS=/some/dir
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:fileswitch/core/api.dart';
import 'package:fileswitch/core/app_state.dart';
import 'package:fileswitch/core/transfers.dart';
import 'package:fileswitch/main.dart' as app;
import 'package:fileswitch/ui/node_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const code = String.fromEnvironment('FS_PAIR_CODE');
const shots = String.fromEnvironment('FS_SHOTS');

Future<void> settle(WidgetTester t, [int ms = 600]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await t.pump();
  }
}

Future<void> waitFor(WidgetTester t, String what, bool Function() cond, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out waiting for $what');
    await settle(t, 250);
  }
}

Future<void> shot(WidgetTester t, String name) async {
  await settle(t, 700);
  if (shots.isEmpty) return;
  final rv = t.binding.renderViews.first;
  final img = await (rv.debugLayer! as OffsetLayer).toImage(Offset.zero & rv.flutterView.physicalSize);
  final bytes = await img.toByteData(format: ImageByteFormat.png);
  await File(p.join(shots, '$name.png')).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('relay mode end to end', (t) async {
    expect(code, isNotEmpty, reason: 'pass --dart-define=FS_PAIR_CODE');
    final cfg = File(p.join((await getApplicationSupportDirectory()).path, 'config.json'));
    if (await cfg.exists()) await cfg.delete();
    await app.main([]);
    await settle(t, 1500);
    final s = AppState.instance;

    // --- pair with the code (no LAN access involved) ---
    await t.tap(find.textContaining('使用配对码').first);
    await settle(t);
    await t.enterText(find.widgetWithText(TextField, '配对码'), code);
    await t.enterText(find.widgetWithText(TextField, '设备名称'), '出差 Mac');
    await shot(t, 'r01_pair');
    await t.tap(find.widgetWithText(FilledButton, '配对'));
    await waitFor(t, 'pairing and first snapshot', () => s.signedIn && s.online && s.categories.isNotEmpty, seconds: 90);
    expect(s.viaRelay, isTrue);
    expect(s.profile!.url, isEmpty, reason: 'paired devices have no LAN address');
    await waitFor(t, 'NAS sync time', () => s.relay?.nasSeen != null);
    await shot(t, 'r02_files_via_relay');
    expect(find.textContaining('经中转站'), findsWidgets);

    // --- upload a folder through the relay ---
    final temp = s.categories.firstWhere((c) => c.name == '临时');
    final dir = await Directory.systemTemp.createTemp('fs-relay-');
    final src = Directory(p.join(dir.path, '出差资料'));
    await Directory(p.join(src.path, '照片', '空目录')).create(recursive: true);
    await File(p.join(src.path, '行程.txt')).writeAsString('北京 → 上海，经中转站端到端加密上传');
    await File(p.join(src.path, '照片', 'big.bin')).writeAsBytes(List.generate(11 << 20, (i) => i * 7 % 251));
    TransferManager.instance.upload([src.path], categoryId: temp.id, destination: temp.name);
    Nav.instance.go(Section.transfers);
    await settle(t, 1500);
    await shot(t, 'r03_uploading');
    // generous: against a real relay this crosses the internet twice (us -> relay -> NAS)
    await waitFor(t, 'upload through relay', () => !TransferManager.instance.items.first.active, seconds: 900);
    final up = TransferManager.instance.items.first;
    expect(up.status, TransferStatus.done, reason: up.error);
    expect(up.doneFiles, 2);
    await shot(t, 'r04_uploaded');

    // it shows up from the NAS's next snapshot
    String? folderId;
    for (var i = 0; i < 120 && folderId == null; i++) {
      final r = await s.api!.search('出差资料');
      if (r.isNotEmpty) folderId = r.first.id;
      await settle(t, 500);
    }
    expect(folderId, isNotNull, reason: 'uploaded folder never appeared in the snapshot');
    final walk = await s.api!.walk(folderId!);
    expect(walk.map((e) => e.relPath).toSet(),
        {'出差资料', '出差资料/照片', '出差资料/行程.txt', '出差资料/照片/空目录', '出差资料/照片/big.bin'});

    // --- download it back through the relay (NAS sends encrypted copies) ---
    final dl = await Directory.systemTemp.createTemp('fs-relay-dl-');
    final (folder, _) = await s.api!.node(folderId);
    final dt = TransferManager.instance.download(folder, toDir: dl.path);
    await dt.finished;
    expect(dt.status, TransferStatus.done, reason: dt.error);
    expect(await File(p.join(dt.localPath!, '行程.txt')).readAsString(), '北京 → 上海，经中转站端到端加密上传');
    expect(await File(p.join(dt.localPath!, '照片', 'big.bin')).readAsBytes(),
        await File(p.join(src.path, '照片', 'big.bin')).readAsBytes());
    expect(await Directory(p.join(dt.localPath!, '照片', '空目录')).exists(), isTrue);

    // --- rename (optimistic, confirmed by the NAS) ---
    final file = walk.firstWhere((e) => e.relPath.endsWith('行程.txt')).node;
    await s.api!.patchNode(file.id, name: '行程-已确认.txt');
    expect((await s.api!.node(file.id)).$1.name, '行程-已确认.txt', reason: 'optimistic update');
    await waitFor(t, 'NAS to confirm the rename', () => (s.relay?.pendingOps ?? 1) == 0, seconds: 60);
    expect((await s.api!.node(file.id)).$1.name, '行程-已确认.txt');

    // --- NAS policy: no permanent deletion from outside ---
    await s.api!.trash(folderId);
    await waitFor(t, 'trash confirmed', () => (s.relay?.pendingOps ?? 1) == 0, seconds: 60);
    expect(s.api!.canPurge, isFalse);
    await expectLater(s.api!.purge(folderId), throwsA(isA<ApiException>()));
    Nav.instance.go(Section.trash);
    await settle(t, 1500);
    await shot(t, 'r05_trash_policy');

    // --- settings in relay mode ---
    Nav.instance.go(Section.settings);
    await waitFor(t, 'settings', () => find.text('已授权的设备').evaluate().isNotEmpty);
    await settle(t, 1500);
    await shot(t, 'r06_settings_relay');
    await t.tap(find.text('添加新设备'));
    await settle(t, 800);
    await shot(t, 'r07_pairing_policy');
    await t.tap(find.text('知道了'));
    await settle(t);

    // --- sign out = revoke this device through the relay ---
    await dir.delete(recursive: true);
    await dl.delete(recursive: true);
    await s.signOut();
    await settle(t, 1000);
    expect(s.signedIn, isFalse);
    if (await cfg.exists()) await cfg.delete();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
