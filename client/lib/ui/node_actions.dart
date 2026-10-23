import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/backend.dart';
import '../core/models.dart';
import '../core/transfers.dart';
import '../platform/shell.dart';
import 'dialogs.dart';
import 'format.dart';

enum Section { files, timeline, categories, category, trash, transfers, settings }

/// Which page is showing; shared by the sidebar, the mobile tabs and the
/// views that jump between each other ("show in folder").
class Nav extends ChangeNotifier {
  Nav._();
  static final Nav instance = Nav._();

  Section section = Section.files;
  String? categoryId;
  String? folderId;
  String? highlightId;
  int folderSerial = 0; // bumps when the files view must navigate

  void go(Section s, {String? categoryId}) {
    section = s;
    if (categoryId != null) this.categoryId = categoryId;
    notifyListeners();
  }

  void openFolder(String? id, {String? highlight}) {
    section = Section.files;
    folderId = id;
    highlightId = highlight;
    folderSerial++;
    notifyListeners();
  }
}

/// Actions on nodes shared by every list (files, timeline, categories).
class NodeActions {
  static Backend get _api => AppState.instance.api!;

  static Future<void> open(BuildContext context, Node n) async {
    if (n.isDir) {
      Nav.instance.openFolder(n.id);
      return;
    }
    if ((n.isImage && n.size < 30 << 20) || (n.isText && n.size < 1 << 20)) {
      await preview(context, n);
      return;
    }
    await openWithSystem(context, n);
  }

  static Future<void> openWithSystem(BuildContext context, Node n) async {
    toast(context, '正在打开 ${n.name}…');
    try {
      final path = await TransferManager.instance.fetchToCache(n);
      await Shell.instance.openLocal(path);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> preview(BuildContext context, Node n) {
    return showDialog(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960, maxHeight: 760),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Icon(nodeIcon(n).$1, color: nodeIcon(n).$2),
              title: Text(n.name, overflow: TextOverflow.ellipsis),
              subtitle: Text('${formatBytes(n.size)} · ${formatTime(n.createdAt)} · ${n.deviceName}'),
              trailing: Wrap(children: [
                IconButton(
                  tooltip: '下载',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () {
                    Navigator.pop(ctx);
                    download(context, [n]);
                  },
                ),
                IconButton(
                  tooltip: isDesktop ? '用默认应用打开' : '分享',
                  icon: Icon(isDesktop ? Icons.open_in_new_rounded : Icons.ios_share_rounded),
                  onPressed: () {
                    Navigator.pop(ctx);
                    openWithSystem(context, n);
                  },
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
            const Divider(height: 1),
            Flexible(
              child: FutureBuilder(
                future: _api.bytes(n),
                builder: (ctx, snap) {
                  if (snap.hasError) return Padding(padding: const EdgeInsets.all(32), child: Text('${snap.error}'));
                  if (!snap.hasData) {
                    return const Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator());
                  }
                  if (n.isImage) {
                    return InteractiveViewer(
                      maxScale: 8,
                      child: Image.memory(snap.data!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              const Padding(padding: EdgeInsets.all(32), child: Text('无法预览该图片格式'))),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(utf8.decode(snap.data!, allowMalformed: true),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  static Future<void> download(BuildContext context, List<Node> nodes, {bool choose = false}) async {
    String? dir;
    if (choose) {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '下载到');
      if (dir == null) return;
    }
    for (final n in nodes) {
      final t = TransferManager.instance.download(n, toDir: dir);
      t.finished.then((_) {
        if (!context.mounted) return;
        if (t.status == TransferStatus.done && t.localPath != null) {
          toast(context, '已下载 ${t.name}',
              action: SnackBarAction(
                  label: isDesktop ? '显示' : '分享', onPressed: () => Shell.instance.revealLocal(t.localPath!)));
        } else if (t.status == TransferStatus.failed) {
          toast(context, '下载失败：${t.error}');
        }
      });
    }
    if (context.mounted) toast(context, nodes.length == 1 ? '开始下载 ${nodes.first.name}' : '开始下载 ${nodes.length} 项');
  }

  static Future<void> rename(BuildContext context, Node n) async {
    final name = await textInput(context, '重命名', initial: n.name, selectBaseName: !n.isDir);
    if (name == null || name.isEmpty || name == n.name) return;
    try {
      await _api.patchNode(n.id, name: name);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> move(BuildContext context, List<Node> nodes) async {
    final target = await pickFolder(context, exclude: {for (final n in nodes) if (n.isDir) n.id});
    if (target == null || !context.mounted) return;
    await moveTo(context, nodes, target);
  }

  static Future<void> moveTo(BuildContext context, List<Node> nodes, String folderId) async {
    final movable = nodes.where((n) => n.id != folderId && n.parentId != folderId).toList();
    if (movable.isEmpty) return;
    try {
      final failed = await _api.batch('move', movable.map((n) => n.id).toList(), parentId: folderId);
      if (!context.mounted) return;
      toast(context, failed.isEmpty ? '已移动 ${movable.length} 项' : '${failed.length} 项移动失败：${failed.values.first}');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> categorize(BuildContext context, List<Node> nodes) async {
    final c = await pickCategory(context, current: nodes.length == 1 ? nodes.first.categoryId : '');
    if (c == null) return;
    if (!context.mounted) return;
    await setCategory(context, nodes, c.id ?? '');
  }

  static Future<void> setCategory(BuildContext context, List<Node> nodes, String categoryId) async {
    try {
      final failed = await _api.batch('categorize', nodes.map((n) => n.id).toList(), categoryId: categoryId);
      if (!context.mounted) return;
      final cat = AppState.instance.categoryById(categoryId);
      toast(context,
          failed.isNotEmpty ? '部分失败：${failed.values.first}' : (cat == null ? '已移除分类' : '已归入「${cat.name}」'));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> trash(BuildContext context, List<Node> nodes) async {
    if (nodes.isEmpty) return;
    final ok = await confirm(
        context, '移到回收站', nodes.length == 1 ? '将「${nodes.first.name}」移到回收站？' : '将选中的 ${nodes.length} 项移到回收站？',
        ok: '删除', danger: true);
    if (!ok) return;
    try {
      await _api.batch('trash', nodes.map((n) => n.id).toList());
      if (!context.mounted) return;
      toast(context, '已移到回收站',
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              for (final n in nodes) {
                try {
                  await _api.restore(n.id);
                } catch (_) {}
              }
            },
          ));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static List<PopupMenuEntry<String>> menuItems(List<Node> nodes, {bool showLocation = false}) {
    final one = nodes.length == 1 ? nodes.first : null;
    PopupMenuItem<String> item(String v, IconData icon, String label, {bool danger = false}) => PopupMenuItem(
          value: v,
          height: 40,
          child: Row(children: [
            Icon(icon, size: 18, color: danger ? Colors.red : null),
            const SizedBox(width: 12),
            Text(label, style: danger ? const TextStyle(color: Colors.red) : null),
          ]),
        );
    return [
      if (one != null) item('open', one.isDir ? Icons.folder_open_rounded : Icons.open_in_new_rounded, '打开'),
      if (showLocation && one != null) item('locate', Icons.my_location_rounded, '打开所在文件夹'),
      item('download', Icons.download_rounded, '下载'),
      if (isDesktop) item('download_to', Icons.drive_folder_upload_rounded, '下载到…'),
      const PopupMenuDivider(),
      if (one != null) item('rename', Icons.edit_rounded, '重命名'),
      item('move', Icons.drive_file_move_rounded, '移动到…'),
      item('category', Icons.label_rounded, '设置分类…'),
      const PopupMenuDivider(),
      item('trash', Icons.delete_rounded, '删除', danger: true),
    ];
  }

  static Future<void> handle(BuildContext context, String action, List<Node> nodes) async {
    switch (action) {
      case 'open':
        await open(context, nodes.first);
      case 'locate':
        Nav.instance.openFolder(nodes.first.parentId, highlight: nodes.first.id);
      case 'download':
        await download(context, nodes);
      case 'download_to':
        await download(context, nodes, choose: true);
      case 'rename':
        await rename(context, nodes.first);
      case 'move':
        await move(context, nodes);
      case 'category':
        await categorize(context, nodes);
      case 'trash':
        await trash(context, nodes);
    }
  }

  static Future<void> showContextMenu(BuildContext context, Offset globalPos, List<Node> nodes,
      {bool showLocation = false}) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: menuItems(nodes, showLocation: showLocation),
    );
    if (v != null && context.mounted) await handle(context, v, nodes);
  }

  /// Mobile: bottom sheet with the same actions.
  static Future<void> showSheet(BuildContext context, Node n, {bool showLocation = false}) async {
    final (icon, color) = nodeIcon(n);
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Icon(icon, color: color, size: 32),
              title: Text(n.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${nodeSubtitle(n)} · ${formatTime(n.createdAt)}${n.deviceName.isEmpty ? '' : ' · ${n.deviceName}'}'),
            ),
            const Divider(),
            for (final e in menuItems([n], showLocation: showLocation))
              if (e is PopupMenuItem<String>)
                ListTile(
                  dense: true,
                  title: e.child,
                  onTap: () => Navigator.pop(ctx, e.value),
                ),
          ]),
        ),
      ),
    );
    if (v != null && context.mounted) await handle(context, v, [n]);
  }
}
