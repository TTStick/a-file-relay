import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/transfers.dart';
import 'dialogs.dart';
import 'files_view.dart';
import 'format.dart';
import 'node_actions.dart';

typedef PageLoader = Future<(List<Node>, bool)> Function(DateTime? before);

/// Newest-first list grouped by day, with infinite scroll and live updates.
class TimeList extends StatefulWidget {
  const TimeList({super.key, required this.loader, required this.reloadKey, this.empty, this.header});
  final PageLoader loader;
  final Object reloadKey;
  final Widget? empty;
  final Widget? header;

  @override
  State<TimeList> createState() => _TimeListState();
}

class _TimeListState extends State<TimeList> {
  final items = <Node>[];
  bool hasMore = true;
  bool loading = false;
  Object? error;
  final scroll = ScrollController();
  StreamSubscription<ServerEvent>? _sub;
  Timer? _reload;

  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (scroll.position.pixels > scroll.position.maxScrollExtent - 400) _more();
    });
    _sub = AppState.instance.events.listen((ev) {
      if (ev.type.startsWith('node.') || ev.type == 'hello' || ev.type == 'category.changed') {
        _reload?.cancel();
        _reload = Timer(const Duration(milliseconds: 300), () => _refresh());
      }
    });
    _refresh();
  }

  @override
  void didUpdateWidget(TimeList old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) {
      items.clear();
      hasMore = true;
      _refresh();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _reload?.cancel();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // Reload at least as many items as currently shown so the view doesn't jump.
      final (list, more) = await widget.loader(null);
      if (!mounted) return;
      setState(() {
        items
          ..clear()
          ..addAll(list);
        hasMore = more;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> _more() async {
    if (loading || !hasMore || items.isEmpty) return;
    loading = true;
    try {
      final (list, more) = await widget.loader(items.last.createdAt);
      if (!mounted) return;
      setState(() {
        items.addAll(list);
        hasMore = more;
      });
    } catch (_) {
    } finally {
      loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$error'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _refresh, child: const Text('重试')),
      ]));
    }
    final rows = <Widget>[if (widget.header != null) widget.header!];
    String? day;
    for (final n in items) {
      final d = formatDay(n.createdAt);
      if (d != day) {
        day = d;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Text(d, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ));
      }
      rows.add(TimeRow(node: n));
    }
    if (items.isEmpty) {
      rows.add(Padding(padding: const EdgeInsets.only(top: 80), child: widget.empty ?? const SizedBox()));
    }
    if (hasMore && items.isNotEmpty) {
      rows.add(const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(controller: scroll, padding: const EdgeInsets.only(bottom: 80), children: rows),
    );
  }
}

class TimeRow extends StatelessWidget {
  const TimeRow({super.key, required this.node});
  final Node node;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final (icon, color) = nodeIcon(n);
    final cat = AppState.instance.categoryById(n.categoryId);
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final desktop = MediaQuery.sizeOf(context).width >= 700;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GestureDetector(
        onSecondaryTapDown: (d) => NodeActions.showContextMenu(context, d.globalPosition, [n], showLocation: true),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color),
          ),
          title: Row(children: [
            Flexible(child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (cat != null) ...[const SizedBox(width: 8), CategoryChip(cat)],
          ]),
          subtitle: Text(
            [
              '${two(n.createdAt.hour)}:${two(n.createdAt.minute)}',
              nodeSubtitle(n),
              if (n.deviceName.isNotEmpty) '来自 ${n.deviceName}',
              if (n.location.isNotEmpty) '位于 ${n.location}',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          trailing: desktop
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: '打开所在文件夹',
                    icon: const Icon(Icons.my_location_rounded, size: 20),
                    onPressed: () => Nav.instance.openFolder(n.parentId, highlight: n.id),
                  ),
                  IconButton(
                    tooltip: '下载',
                    icon: const Icon(Icons.download_rounded, size: 20),
                    onPressed: () => NodeActions.download(context, [n]),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    itemBuilder: (_) => NodeActions.menuItems([n], showLocation: true),
                    onSelected: (v) => NodeActions.handle(context, v, [n]),
                  ),
                ])
              : IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => NodeActions.showSheet(context, n, showLocation: true),
                ),
          onTap: () => n.isDir ? Nav.instance.openFolder(n.id) : NodeActions.open(context, n),
        ),
      ),
    );
  }
}

class TimelineView extends StatefulWidget {
  const TimelineView({super.key});

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  String filter = '';

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final chips = SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            children: [
              _chip('全部', ''),
              for (final c in s.categories) _chip(c.name, c.id, color: c.color, icon: c.icon),
              _chip('未分类', 'none'),
            ],
          ),
        );
        final list = TimeList(
          reloadKey: filter,
          loader: (before) => s.api!.timeline(before: before, category: filter),
          empty: const _Empty(icon: Icons.history_rounded, text: '还没有投递记录', hint: '上传或拖拽到托盘的文件会按时间出现在这里'),
        );
        if (MediaQuery.sizeOf(context).width < 700) {
          return Scaffold(
            appBar: AppBar(title: const Text('时间线'), bottom: PreferredSize(preferredSize: const Size.fromHeight(48), child: chips)),
            body: list,
          );
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              Text('时间线', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text('按投递时间排列的所有文件与文件夹', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          chips,
          const Divider(height: 1),
          Expanded(child: list),
        ]);
      },
    );
  }

  Widget _chip(String label, String id, {Color? color, String icon = ''}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: filter == id,
        showCheckmark: false,
        avatar: color == null
            ? null
            : (icon.isNotEmpty ? Text(icon) : CircleAvatar(backgroundColor: color, radius: 5)),
        label: Text(label),
        onSelected: (_) => setState(() => filter = id),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text, this.hint});
  final IconData icon;
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
      const SizedBox(height: 12),
      Text(text, style: Theme.of(context).textTheme.titleMedium),
      if (hint != null) ...[const SizedBox(height: 6), Text(hint!, style: Theme.of(context).textTheme.bodySmall)],
    ]);
  }
}

/// Everything tagged with one category.
class CategoryView extends StatelessWidget {
  const CategoryView({super.key, required this.categoryId});
  final String categoryId;

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final c = s.categoryById(categoryId);
        if (c == null) return const Center(child: Text('分类不存在'));
        final narrow = MediaQuery.sizeOf(context).width < 700;
        final actions = [
          IconButton(
            tooltip: '打开分类文件夹',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: () async {
              try {
                // make sure the folder exists (it's created on first use)
                final id = c.folderId.isNotEmpty
                    ? c.folderId
                    : (await s.api!.createFolder(categoryId: c.id, name: c.name, conflict: 'merge')).id;
                Nav.instance.openFolder(id);
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          IconButton(tooltip: '编辑分类', icon: const Icon(Icons.edit_rounded), onPressed: () => editCategoryFlow(context, c)),
          IconButton(
            tooltip: '删除分类',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => deleteCategoryFlow(context, c),
          ),
        ];
        final upload = FilledButton.icon(
          onPressed: () => pickAndUpload(context, categoryId: c.id, destination: c.name),
          icon: const Icon(Icons.upload_rounded, size: 18),
          label: const Text('上传到此分类'),
        );
        final list = OsDropZone(
          label: '松手上传到「${c.name}」',
          onDrop: (paths) {
            TransferManager.instance.upload(paths, categoryId: c.id, destination: c.name);
            toast(context, '已开始上传 ${paths.length} 项到「${c.name}」');
          },
          child: TimeList(
            reloadKey: c.id,
            loader: (before) => s.api!.tagged(c.id, before: before),
            empty: _Empty(
              icon: Icons.label_outline_rounded,
              text: '「${c.name}」里还没有文件',
              hint: isDesktop ? '把文件拖到这里，或拖到菜单栏/托盘的投递面板上' : '点击上传按钮添加文件',
            ),
          ),
        );
        if (narrow) {
          return Scaffold(
            appBar: AppBar(title: Row(children: [CategoryDot(c, size: 14), const SizedBox(width: 8), Text(c.name)]), actions: actions),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => pickAndUpload(context, categoryId: c.id, destination: c.name),
              icon: const Icon(Icons.upload_rounded),
              label: const Text('上传'),
            ),
            body: list,
          );
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
            child: Row(children: [
              CategoryDot(c, size: 16),
              const SizedBox(width: 10),
              Text(c.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text('${c.count} 项', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              ...actions,
              const SizedBox(width: 8),
              upload,
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: list),
        ]);
      },
    );
  }
}

Future<void> createCategoryFlow(BuildContext context) async {
  final r = await editCategory(context);
  if (r == null) return;
  if (AppState.instance.viaRelay && context.mounted) toast(context, '已提交，等待 NAS 同步后出现…');
  try {
    final c = await AppState.instance.api!.createCategory(r.$1, r.$2, r.$3);
    await AppState.instance.refreshCategories();
    Nav.instance.go(Section.category, categoryId: c.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> editCategoryFlow(BuildContext context, Category c) async {
  final r = await editCategory(context, existing: c);
  if (r == null) return;
  try {
    await AppState.instance.api!.updateCategory(c.id, name: r.$1, color: r.$2, icon: r.$3);
    await AppState.instance.refreshCategories();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> deleteCategoryFlow(BuildContext context, Category c) async {
  final ok = await confirm(context, '删除分类「${c.name}」', '只删除分类标签，文件和文件夹都会保留。', ok: '删除', danger: true);
  if (!ok) return;
  try {
    await AppState.instance.api!.deleteCategory(c.id);
    await AppState.instance.refreshCategories();
    if (Nav.instance.categoryId == c.id) Nav.instance.go(Section.files);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Mobile tab: grid of categories.
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('分类'), actions: [
          IconButton(icon: const Icon(Icons.add_rounded), onPressed: () => createCategoryFlow(context)),
        ]),
        body: s.categories.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const _Empty(icon: Icons.label_outline_rounded, text: '还没有分类', hint: '分类用来快速投递与整理文件'),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => createCategoryFlow(context), child: const Text('新建分类')),
                ]),
              )
            : GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.6,
                children: [
                  for (final c in s.categories)
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Nav.instance.go(Section.category, categoryId: c.id),
                      child: Ink(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: c.color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          c.icon.isNotEmpty
                              ? Text(c.icon, style: const TextStyle(fontSize: 24))
                              : Icon(Icons.label_rounded, color: c.color),
                          const Spacer(),
                          Text(c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w700, color: c.color, fontSize: 16)),
                          Text('${c.count} 项', style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
