import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/transfers.dart';
import '../platform/shell.dart';
import 'format.dart';
import 'node_actions.dart';

class TransfersView extends StatelessWidget {
  const TransfersView({super.key});

  @override
  Widget build(BuildContext context) {
    final tm = TransferManager.instance;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return ListenableBuilder(
      listenable: tm,
      builder: (context, _) {
        final clear = TextButton.icon(
          onPressed: tm.items.any((t) => !t.active) ? tm.clearFinished : null,
          icon: const Icon(Icons.clear_all_rounded),
          label: const Text('清除已完成'),
        );
        final body = tm.items.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.swap_vert_rounded, size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  const Text('没有传输任务'),
                ]),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: tm.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (_, i) => TransferTile(t: tm.items[i]),
              );
        if (narrow) return Scaffold(appBar: AppBar(title: const Text('传输'), actions: [clear]), body: body);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
            child: Row(children: [
              Text('传输', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text('${tm.activeCount} 项进行中', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              clear,
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ]);
      },
    );
  }
}

class TransferTile extends StatelessWidget {
  const TransferTile({super.key, required this.t, this.compact = false});
  final Transfer t;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final up = t.kind == TransferKind.upload;
    final (statusText, statusColor) = switch (t.status) {
      TransferStatus.queued => ('等待中', cs.outline),
      TransferStatus.running => (t.phase ?? '${(t.progress * 100).floor()}%  ${formatSpeed(t.speed)}', cs.primary),
      TransferStatus.done => (up ? '已上传' : '已下载', Colors.green),
      TransferStatus.failed => (t.error ?? '失败', cs.error),
      TransferStatus.canceled => ('已取消', cs.outline),
    };
    final detail = [
      if (t.totalBytes > 0) '${formatBytes(t.doneBytes)} / ${formatBytes(t.totalBytes)}',
      if (t.isFolder && t.totalFiles > 0) '${t.doneFiles}/${t.totalFiles} 个文件',
      if (t.destination.isNotEmpty) '→ ${t.destination}',
    ].join(' · ');
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(children: [
          Icon(
            t.isFolder
                ? Icons.folder_rounded
                : up
                    ? Icons.upload_file_rounded
                    : Icons.download_for_offline_rounded,
            color: up ? cs.primary : cs.tertiary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              if (t.active)
                LinearProgressIndicator(
                  value: t.status == TransferStatus.queued || t.phase != null ? null : t.progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              const SizedBox(height: 4),
              Text(
                compact ? statusText : [statusText, if (detail.isNotEmpty) detail].join('   '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
            ]),
          ),
          if (t.active)
            IconButton(tooltip: '取消', icon: const Icon(Icons.close_rounded), onPressed: () => TransferManager.instance.cancel(t))
          else ...[
            if (!up && t.status == TransferStatus.done && t.localPath != null) ...[
              if (isDesktop)
                IconButton(
                    tooltip: '打开',
                    icon: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => Shell.instance.openLocal(t.localPath!)),
              IconButton(
                  tooltip: Shell.instance.revealLabel,
                  icon: Icon(isDesktop ? Icons.folder_open_rounded : Icons.ios_share_rounded),
                  onPressed: () => Shell.instance.revealLocal(t.localPath!)),
            ],
            if (up && t.status == TransferStatus.done && t.node != null)
              IconButton(
                tooltip: '在交换站中查看',
                icon: const Icon(Icons.my_location_rounded),
                onPressed: () => Nav.instance.openFolder(t.node!.parentId, highlight: t.node!.id),
              ),
            IconButton(
                tooltip: '移除', icon: const Icon(Icons.close_rounded), onPressed: () => TransferManager.instance.remove(t)),
          ],
        ]),
      ),
    );
  }
}
