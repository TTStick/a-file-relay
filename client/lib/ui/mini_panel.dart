import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import '../core/transfers.dart';
import '../platform/shell.dart';
import 'dialogs.dart';
import 'files_view.dart';

/// Windows: a small always-on-top window above the tray with one drop zone
/// per category — the counterpart of the macOS menu-bar drop panel.
class MiniPanel extends StatelessWidget {
  const MiniPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final tm = TransferManager.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([s, tm]),
        builder: (context, _) {
          final pr = tm.uploadProgress;
          Widget tile(String label, Color color, String icon, String? catId) => OsDropZone(
                label: '松手上传',
                radius: 12,
                onDrop: (paths) {
                  TransferManager.instance.upload(paths, categoryId: catId, destination: label);
                  toast(context, '已开始上传 ${paths.length} 项到「$label」');
                },
                child: Container(
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(children: [
                    icon.isNotEmpty
                        ? Text(icon, style: const TextStyle(fontSize: 18))
                        : Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(label,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              );
          return Column(children: [
            DragToMoveArea(
              child: Container(
                color: cs.surfaceContainer,
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                child: Row(children: [
                  const Icon(Icons.swap_horiz_rounded, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('投递到 ${s.info?.name ?? 'FileSwitch'}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(s.signedIn ? '把文件拖到分类上松手即上传' : '请先登录', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                  IconButton(
                    tooltip: '打开主窗口',
                    icon: const Icon(Icons.open_in_full_rounded, size: 18),
                    onPressed: () => Shell.instance.showMain(),
                  ),
                  IconButton(
                    tooltip: '隐藏',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () async {
                      await Shell.instance.setMiniMode(false);
                      await Shell.instance.hideMain();
                    },
                  ),
                ]),
              ),
            ),
            Expanded(
              child: !s.signedIn
                  ? Center(child: FilledButton(onPressed: Shell.instance.showMain, child: const Text('登录')))
                  : GridView.count(
                      padding: const EdgeInsets.all(12),
                      crossAxisCount: 2,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.6,
                      children: [
                        tile('全部文件', cs.primary, '', null),
                        for (final c in s.categories) tile(c.name, c.color, c.icon, c.id),
                      ],
                    ),
            ),
            if (pr != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(children: [
                  Expanded(child: LinearProgressIndicator(value: pr, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 8),
                  Text('${(pr * 100).floor()}%', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}
