import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'dialogs.dart';
import 'format.dart';

class TrashView extends StatefulWidget {
  const TrashView({super.key});

  @override
  State<TrashView> createState() => _TrashViewState();
}

class _TrashViewState extends State<TrashView> {
  List<Node>? items;
  Object? error;
  StreamSubscription<ServerEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = AppState.instance.events.listen((ev) {
      if (ev.type == 'node.trashed' || ev.type == 'trash.changed' || ev.type == 'node.created' || ev.type == 'hello') _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await AppState.instance.api!.trashList();
      if (mounted) setState(() => items = l);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> _restore(Node n) async {
    try {
      final r = await AppState.instance.api!.restore(n.id);
      if (mounted) toast(context, '已恢复「${r.name}」');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _purge(Node n) async {
    if (!await confirm(context, '彻底删除', '「${n.name}」将被永久删除，无法恢复。', ok: '彻底删除', danger: true)) return;
    try {
      await AppState.instance.api!.purge(n.id);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _empty() async {
    if (!await confirm(context, '清空回收站', '回收站中的所有项目将被永久删除，无法恢复。', ok: '清空', danger: true)) return;
    try {
      await AppState.instance.api!.emptyTrash();
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = items;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final canPurge = AppState.instance.api?.canPurge ?? false;
    final body = l == null
        ? Center(child: error != null ? Text('$error') : const CircularProgressIndicator())
        : l.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.delete_outline_rounded, size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  const Text('回收站是空的'),
                ]),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: l.length,
                itemBuilder: (_, i) {
                  final n = l[i];
                  final (icon, color) = nodeIcon(n);
                  return ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${nodeSubtitle(n)} · 删除于 ${formatTime(n.trashedAt ?? n.updatedAt)}'
                      '${n.location.isEmpty ? '' : ' · 原位置 ${n.location}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton(onPressed: () => _restore(n), child: const Text('恢复')),
                      IconButton(
                        tooltip: canPurge ? '彻底删除' : 'NAS 设置不允许远程彻底删除',
                        icon: const Icon(Icons.delete_forever_rounded),
                        onPressed: canPurge ? () => _purge(n) : null,
                      ),
                    ]),
                  );
                },
              );
    final emptyBtn = TextButton.icon(
      onPressed: (l?.isEmpty ?? true) || !canPurge ? null : _empty,
      icon: const Icon(Icons.delete_sweep_rounded),
      label: const Text('清空回收站'),
    );
    final days = canPurge
        ? '回收站中的项目会在一段时间后自动永久删除'
        : '经中转站时只能恢复，彻底删除需在局域网内操作（NAS 安全策略）';
    if (narrow) {
      return Scaffold(appBar: AppBar(title: const Text('回收站'), actions: [emptyBtn]), body: body);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
        child: Row(children: [
          Text('回收站', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Expanded(child: Text(days, style: Theme.of(context).textTheme.bodySmall)),
          emptyBtn,
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: body),
    ]);
  }
}
