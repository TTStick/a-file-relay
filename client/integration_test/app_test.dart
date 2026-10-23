// End-to-end test of the desktop client against a running FileSwitch server.
//
//   flutter test integration_test -d macos \
//     --dart-define=FS_TEST_URL=127.0.0.1:18443 \
//     --dart-define=FS_TEST_USER=admin --dart-define=FS_TEST_PASS=... \
//     --dart-define=FS_SHOTS=/some/dir
//
// It signs in through the UI (including the certificate-fingerprint prompt),
// walks every page, simulates a drop on the macOS menu-bar panel, and writes
// a screenshot of each step to FS_SHOTS.
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:fileswitch/core/app_state.dart';
import 'package:fileswitch/core/transfers.dart';
import 'package:fileswitch/main.dart' as app;
import 'package:fileswitch/ui/node_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const url = String.fromEnvironment('FS_TEST_URL', defaultValue: '127.0.0.1:18443');
const user = String.fromEnvironment('FS_TEST_USER', defaultValue: 'admin');
const pass = String.fromEnvironment('FS_TEST_PASS');
const shots = String.fromEnvironment('FS_SHOTS');

Future<void> settle(WidgetTester t, [int ms = 600]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await t.pump();
  }
}

Future<void> waitFor(WidgetTester t, bool Function() cond, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out waiting');
    await settle(t, 200);
  }
}

Future<void> shot(WidgetTester t, String name) async {
  await settle(t, 700);
  if (shots.isEmpty) return;
  final rv = t.binding.renderViews.first;
  final layer = rv.debugLayer! as OffsetLayer;
  final img = await layer.toImage(Offset.zero & rv.flutterView.physicalSize);
  final bytes = await img.toByteData(format: ImageByteFormat.png);
  await File(p.join(shots, '$name.png')).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop end to end', (t) async {
    // Start from a clean slate so the connect flow is exercised.
    final cfg = File(p.join((await getApplicationSupportDirectory()).path, 'config.json'));
    if (await cfg.exists()) await cfg.delete();

    await app.main([]);
    await settle(t, 1500);
    final s = AppState.instance;

    // --- add server + trust fingerprint ---
    await t.enterText(find.byType(TextField).first, url);
    await t.tap(find.widgetWithText(FilledButton, '连接'));
    await waitFor(t, () => find.text('验证服务器身份').evaluate().isNotEmpty);
    await shot(t, '01_fingerprint');
    await t.tap(find.text('指纹一致，信任'));
    await settle(t);

    // --- sign in ---
    await t.enterText(find.widgetWithText(TextField, '用户名'), user);
    await t.enterText(find.widgetWithText(TextField, '密码'), pass);
    await t.enterText(find.widgetWithText(TextField, '设备名称'), Platform.isIOS ? 'iPhone 16' : 'MacBook Pro');
    await shot(t, '02_login');
    await t.tap(find.widgetWithText(FilledButton, '登录'));
    await waitFor(t, () => s.signedIn && s.online && s.categories.isNotEmpty);
    expect(s.profile!.fingerprint, isNotNull, reason: 'self-signed cert must be pinned');
    expect(s.viaRelay, isFalse, reason: 'on the LAN the app talks to the NAS directly');
    if (s.info!.relayUrl.isNotEmpty) {
      // a NAS with a relay enrolls LAN devices so they keep working away from home
      await waitFor(t, () => s.profile!.relayUrl.isNotEmpty);
    }
    await shot(t, '03_files_root');

    // --- folder view with tree ---
    final root = await s.api!.list(null);
    final work = root.children.firstWhere((n) => n.name == '工作');
    Nav.instance.openFolder(work.id);
    await waitFor(t, () => find.text('预算表.xlsx').evaluate().isNotEmpty);
    await shot(t, '04_folder_work');

    // --- timeline ---
    Nav.instance.go(Section.timeline);
    await waitFor(t, () => find.text('待办.md').evaluate().isNotEmpty);
    await shot(t, '05_timeline');

    // --- category page ---
    final photos = s.categories.firstWhere((c) => c.name == '照片');
    Nav.instance.go(Section.category, categoryId: photos.id);
    await waitFor(t, () => find.text('IMG_2041.HEIC').evaluate().isNotEmpty);
    await shot(t, '06_category');

    // --- simulate a folder dropped on the macOS menu-bar panel ---
    final temp = s.categories.firstWhere((c) => c.name == '临时');
    final dir = await Directory.systemTemp.createTemp('fs-drop-');
    final dropped = Directory(p.join(dir.path, '拖拽测试'));
    await Directory(p.join(dropped.path, '子目录', '空目录')).create(recursive: true);
    await File(p.join(dropped.path, 'a.txt')).writeAsString('hello from the drop panel');
    await File(p.join(dropped.path, '子目录', 'b.bin')).writeAsBytes(List.filled(9 << 20, 7)); // chunked path
    await File(p.join(dropped.path, '.DS_Store')).writeAsString('junk');
    if (Platform.isMacOS) {
      // exactly what the native panel sends when files are released on a tile
      final msg = const StandardMethodCodec().encodeMethodCall(MethodCall('drop', {
        'categoryId': temp.id,
        'paths': [dropped.path],
      }));
      // ignore: deprecated_member_use
      await t.binding.defaultBinaryMessenger.handlePlatformMessage('fileswitch/macos', msg, (_) {});
    } else {
      TransferManager.instance.upload([dropped.path], categoryId: temp.id, destination: temp.name);
    }
    Nav.instance.go(Section.transfers);
    await settle(t, 300);
    await shot(t, '07_transfers_running');
    await waitFor(t, () => TransferManager.instance.items.isNotEmpty && !TransferManager.instance.items.first.active,
        seconds: 60);
    final tr = TransferManager.instance.items.first;
    expect(tr.status, TransferStatus.done, reason: tr.error);
    expect(tr.doneFiles, 2, reason: '.DS_Store must be skipped');
    await shot(t, '08_transfers_done');

    // the folder is in the category folder, tagged, with the empty dir preserved
    final walk = await s.api!.walk(tr.node!.id);
    expect(walk.map((e) => e.relPath).toSet(),
        {'拖拽测试', '拖拽测试/子目录', '拖拽测试/a.txt', '拖拽测试/子目录/空目录', '拖拽测试/子目录/b.bin'});
    expect(tr.node!.categoryId, temp.id);

    // --- download it back and compare ---
    final dl = await Directory.systemTemp.createTemp('fs-dl-');
    final dt = TransferManager.instance.download(tr.node!, toDir: dl.path);
    await dt.finished;
    expect(dt.status, TransferStatus.done, reason: dt.error);
    expect(await File(p.join(dt.localPath!, '子目录', 'b.bin')).length(), 9 << 20);
    expect(await File(p.join(dt.localPath!, 'a.txt')).readAsString(), 'hello from the drop panel');
    expect(await Directory(p.join(dt.localPath!, '子目录', '空目录')).exists(), isTrue);

    // --- text preview ---
    Nav.instance.openFolder(tr.node!.id);
    await waitFor(t, () => find.text('a.txt').evaluate().isNotEmpty);
    final listing = await s.api!.list(tr.node!.id);
    NodeActions.preview(t.element(find.text('a.txt')), listing.children.firstWhere((n) => n.name == 'a.txt'));
    await waitFor(t, () => find.text('hello from the drop panel').evaluate().isNotEmpty);
    await shot(t, '09_preview');
    Navigator.of(t.element(find.text('hello from the drop panel'))).pop();
    await settle(t);

    // --- settings / security ---
    Nav.instance.go(Section.settings);
    await waitFor(t, () => find.text('已授权的设备').evaluate().isNotEmpty);
    await settle(t, 1500);
    await shot(t, '10_settings');

    // --- add a device: pairing QR code (needs a relay on the NAS) ---
    if (s.info!.relayUrl.isNotEmpty) {
      await t.ensureVisible(find.text('添加新设备'));
      await settle(t);
      await t.tap(find.text('添加新设备'));
      await waitFor(t, () => find.text('复制配对码').evaluate().isNotEmpty);
      await shot(t, '12_pair_qr');
      await t.tap(find.text('完成'));
      await settle(t);
    }

    // --- native drop panel (rendered offscreen by the debug hook) ---
    if (Platform.isMacOS && shots.isNotEmpty) {
      final ok = await const MethodChannel('fileswitch/macos').invokeMethod<bool>('debugSnapshotPanel', p.join(shots, '11_panel.png'));
      expect(ok, isTrue);
    }

    // --- clean up what the test created ---
    await s.api!.trash(tr.node!.id);
    await s.api!.purge(tr.node!.id);
    await dir.delete(recursive: true);
    await dl.delete(recursive: true);
    await s.signOut();
    await settle(t);
    expect(find.text('选择交换站'), findsOneWidget);
    if (await cfg.exists()) await cfg.delete();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
