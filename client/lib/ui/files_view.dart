import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/transfers.dart';
import 'dialogs.dart';
import 'format.dart';
import 'node_actions.dart';

/// Picks local files (or a folder) and queues them for upload.
Future<void> pickAndUpload(BuildContext context,
    {String? parentId, String? categoryId, String destination = '', bool folder = false, FileType type = FileType.any}) async {
  final paths = <String>[];
  if (folder) {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '选择要上传的文件夹');
    if (d != null) paths.add(d);
  } else {
    final files = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件', type: type);
    paths.addAll(files.map((f) => f.path).whereType<String>());
  }
  if (paths.isEmpty) return;
  TransferManager.instance.upload(paths, parentId: parentId, categoryId: categoryId, destination: destination);
  if (context.mounted) toast(context, '已开始上传 ${paths.length} 项');
}

/// Wraps [child] so files dropped from the OS are uploaded via [onDrop].
class OsDropZone extends StatefulWidget {
  const OsDropZone({super.key, required this.child, required this.onDrop, required this.label, this.radius = 12});
  final Widget child;
  final void Function(List<String> paths) onDrop;
  final String label;
  final double radius;

  @override
  State<OsDropZone> createState() => _OsDropZoneState();
}

class _OsDropZoneState extends State<OsDropZone> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return widget.child;
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => hover = true),
      onDragExited: (_) => setState(() => hover = false),
      onDragDone: (d) {
        setState(() => hover = false);
        final paths = d.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) widget.onDrop(paths);
      },
      child: Stack(children: [
        widget.child,
        if (hover)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  border: Border.all(color: cs.primary, width: 2),
                  borderRadius: BorderRadius.circular(widget.radius),
                ),
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(24)),
                  child: Text(widget.label, style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

enum SortKey { name, time, size }

class FilesView extends StatefulWidget {
  const FilesView({super.key});

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<FilesView> {
  final nav = Nav.instance;
  int _serial = -1;
  String? folderId;
  Listing? listing;
  bool loading = false;
  Object? error;
  final selected = <String>{};
  String? anchor;
  SortKey sort = SortKey.name;
  bool asc = true;
  final searchCtrl = TextEditingController();
  List<Node>? results;
  Timer? _reload;
  Timer? _searchDebounce;
  StreamSubscription<ServerEvent>? _sub;
  final focus = FocusNode();
  String? _lastTapId;
  DateTime _lastTapAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    _serial = nav.folderSerial;
    folderId = nav.folderId;
    _selectHighlight();
    nav.addListener(_onNav);
    _sub = AppState.instance.events.listen(_onEvent);
    load();
  }

  @override
  void dispose() {
    nav.removeListener(_onNav);
    _sub?.cancel();
    _reload?.cancel();
    _searchDebounce?.cancel();
    focus.dispose();
    super.dispose();
  }

  void _selectHighlight() {
    selected.clear();
    if (nav.highlightId != null) selected.add(nav.highlightId!);
    nav.highlightId = null;
  }

  void _onNav() {
    if (nav.folderSerial != _serial) {
      _serial = nav.folderSerial;
      folderId = nav.folderId;
      searchCtrl.clear();
      results = null;
      _selectHighlight();
      load();
    }
  }

  void _onEvent(ServerEvent ev) {
    final cur = listing?.parent.id;
    if (ev.type == 'hello' ||
        ev.type == 'trash.changed' ||
        (cur != null && (ev.parentId == cur || ev.oldParentId == cur || ev.node?.id == cur))) {
      _reload?.cancel();
      _reload = Timer(const Duration(milliseconds: 250), () {
        load(quiet: true);
        if (results != null) _search(searchCtrl.text);
      });
    }
  }

  Future<void> load({bool quiet = false}) async {
    final api = AppState.instance.api;
    if (api == null) return;
    if (!quiet) setState(() => loading = true);
    try {
      final l = await api.list(folderId);
      if (!mounted) return;
      setState(() {
        listing = l;
        error = null;
        loading = false;
        selected.retainAll(l.children.map((c) => c.id));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e;
        // the folder may have been deleted elsewhere: fall back to the root
        if (folderId != null && e.toString().contains('不存在')) {
          folderId = null;
          load();
        }
      });
    }
  }

  void _search(String q) {
    _searchDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => results = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await AppState.instance.api!.search(q.trim());
        if (mounted && searchCtrl.text.trim() == q.trim()) setState(() => results = r);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  void open(String? id) {
    nav.openFolder(id);
  }

  List<Node> get items {
    final list = [...(results ?? listing?.children ?? <Node>[])];
    int cmp(Node a, Node b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final r = switch (sort) {
        SortKey.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortKey.time => a.createdAt.compareTo(b.createdAt),
        SortKey.size => (a.isDir ? a.childCount : a.size).compareTo(b.isDir ? b.childCount : b.size),
      };
      return asc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  List<Node> get selectedNodes => items.where((n) => selected.contains(n.id)).toList();

  void _tap(Node n, List<Node> all) {
    focus.requestFocus();
    final now = DateTime.now();
    final isDouble = _lastTapId == n.id && now.difference(_lastTapAt) < const Duration(milliseconds: 400);
    _lastTapId = n.id;
    _lastTapAt = now;
    if (isDouble) {
      NodeActions.open(context, n);
      return;
    }
    final kb = HardwareKeyboard.instance;
    setState(() {
      if (kb.isShiftPressed && anchor != null) {
        final a = all.indexWhere((x) => x.id == anchor);
        final b = all.indexWhere((x) => x.id == n.id);
        if (a >= 0 && b >= 0) {
          selected
            ..clear()
            ..addAll(all.sublist(a < b ? a : b, (a < b ? b : a) + 1).map((x) => x.id));
          return;
        }
      }
      if (kb.isMetaPressed || kb.isControlPressed) {
        selected.contains(n.id) ? selected.remove(n.id) : selected.add(n.id);
      } else {
        selected
          ..clear()
          ..add(n.id);
      }
      anchor = n.id;
    });
  }

  void _secondary(Node n, Offset pos) {
    if (!selected.contains(n.id)) {
      setState(() {
        selected
          ..clear()
          ..add(n.id);
        anchor = n.id;
      });
    }
    NodeActions.showContextMenu(context, pos, selectedNodes, showLocation: results != null);
  }

  void _drop(List<String> paths) {
    final l = listing;
    if (l == null) return;
    TransferManager.instance.upload(paths, parentId: l.parent.id, destination: _folderName(l));
    toast(context, '已开始上传 ${paths.length} 项到「${_folderName(l)}」');
  }

  String _folderName(Listing l) => l.path.length <= 1 ? '全部文件' : l.path.last.name;

  Future<void> _newFolder() async {
    final l = listing;
    if (l == null) return;
    final name = await textInput(context, '新建文件夹', label: '名称', initial: '新建文件夹');
    if (name == null || name.isEmpty) return;
    if (AppState.instance.viaRelay && mounted) toast(context, '正在等待 NAS 创建文件夹…');
    try {
      final n = await AppState.instance.api!.createFolder(parentId: l.parent.id, name: name);
      setState(() => selected
        ..clear()
        ..add(n.id));
      load(quiet: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return wide ? _desktop(context) : _mobile(context);
  }

  // --- desktop ---

  Widget _desktop(BuildContext context) {
    final all = items;
    final showTree = MediaQuery.sizeOf(context).width >= 1100;
    return Row(children: [
      if (showTree) ...[
        SizedBox(width: 230, child: FolderTree(currentPath: listing?.path ?? const [])),
        const VerticalDivider(width: 1),
      ],
      Expanded(
        child: Column(children: [
          _toolbar(context),
          if (selected.length > 1) _selectionBar(context),
          _header(context),
          const Divider(height: 1),
          Expanded(
            child: OsDropZone(
              label: listing == null ? '松手上传' : '松手上传到「${_folderName(listing!)}」',
              onDrop: _drop,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.delete): () => NodeActions.trash(context, selectedNodes),
                  const SingleActivator(LogicalKeyboardKey.backspace, meta: true): () =>
                      NodeActions.trash(context, selectedNodes),
                  const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
                      setState(() => selected.addAll(all.map((n) => n.id))),
                  const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                      setState(() => selected.addAll(all.map((n) => n.id))),
                  const SingleActivator(LogicalKeyboardKey.f2): () {
                    if (selectedNodes.length == 1) NodeActions.rename(context, selectedNodes.first);
                  },
                  const SingleActivator(LogicalKeyboardKey.enter): () {
                    if (selectedNodes.length == 1) NodeActions.open(context, selectedNodes.first);
                  },
                  const SingleActivator(LogicalKeyboardKey.escape): () => setState(selected.clear),
                },
                child: Focus(
                  focusNode: focus,
                  autofocus: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      focus.requestFocus();
                      setState(selected.clear);
                    },
                    child: _body(context, all, (n) => _DesktopRow(
                          node: n,
                          selected: selected.contains(n.id),
                          showLocation: results != null,
                          dragNodes: () => selected.contains(n.id) ? selectedNodes : [n],
                          onTap: () => _tap(n, all),
                          onSecondary: (pos) => _secondary(n, pos),
                        )),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _body(BuildContext context, List<Node> all, Widget Function(Node) row) {
    if (listing == null && loading) return const Center(child: CircularProgressIndicator());
    if (listing == null && error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$error'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: load, child: const Text('重试')),
        ]),
      );
    }
    if (all.isEmpty) {
      final t = Theme.of(context).textTheme;
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(results != null ? Icons.search_off_rounded : Icons.cloud_upload_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(results != null ? '没有找到匹配的文件' : '这里还是空的', style: t.titleMedium),
          if (results == null) ...[
            const SizedBox(height: 6),
            Text(isDesktop ? '把文件或文件夹拖到这里即可上传' : '点击右下角按钮上传文件', style: t.bodySmall),
          ],
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: () => load(quiet: true),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 80),
        itemCount: all.length,
        itemBuilder: (_, i) => row(all[i]),
      ),
    );
  }

  Widget _breadcrumb(BuildContext context) {
    final path = listing?.path ?? const <Crumb>[];
    if (results != null) {
      return Text('搜索结果 · ${results!.length} 项', style: Theme.of(context).textTheme.titleMedium);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: [
        for (var i = 0; i < path.length; i++) ...[
          if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: Theme.of(context).colorScheme.outline),
          _CrumbButton(crumb: path[i], isRoot: i == 0, isLast: i == path.length - 1),
        ],
      ]),
    );
  }

  Widget _toolbar(BuildContext context) {
    final l = listing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
      child: Row(children: [
        if ((l?.path.length ?? 0) > 1 && results == null)
          IconButton(
            tooltip: '上一级',
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: () => open(l!.path[l.path.length - 2].id),
          ),
        Expanded(child: _breadcrumb(context)),
        const SizedBox(width: 12),
        SizedBox(
          width: 220,
          height: 38,
          child: TextField(
            controller: searchCtrl,
            onChanged: _search,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索全部文件',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        searchCtrl.clear();
                        _search('');
                      }),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(tooltip: '新建文件夹', icon: const Icon(Icons.create_new_folder_outlined), onPressed: _newFolder),
        IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh_rounded), onPressed: load),
        const SizedBox(width: 4),
        MenuAnchor(
          builder: (ctx, ctrl, _) => FilledButton.icon(
            onPressed: l == null ? null : () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: const Text('上传'),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.insert_drive_file_outlined),
              onPressed: () => pickAndUpload(context, parentId: l!.parent.id, destination: _folderName(l)),
              child: const Text('上传文件'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.folder_outlined),
              onPressed: () => pickAndUpload(context, parentId: l!.parent.id, destination: _folderName(l), folder: true),
              child: const Text('上传文件夹'),
            ),
          ],
        ),
      ]),
    );
  }

  Widget _selectionBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nodes = selectedNodes;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Text('已选择 ${nodes.length} 项', style: TextStyle(color: cs.onSecondaryContainer)),
        const Spacer(),
        TextButton.icon(
            onPressed: () => NodeActions.download(context, nodes),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('下载')),
        TextButton.icon(
            onPressed: () => NodeActions.move(context, nodes),
            icon: const Icon(Icons.drive_file_move_rounded, size: 18),
            label: const Text('移动')),
        TextButton.icon(
            onPressed: () => NodeActions.categorize(context, nodes),
            icon: const Icon(Icons.label_rounded, size: 18),
            label: const Text('分类')),
        TextButton.icon(
            onPressed: () => NodeActions.trash(context, nodes),
            icon: const Icon(Icons.delete_rounded, size: 18),
            label: const Text('删除')),
        IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(selected.clear)),
      ]),
    );
  }

  Widget _header(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline);
    Widget h(String label, SortKey? key, {int flex = 0, double? width, TextAlign align = TextAlign.left}) {
      final active = key != null && sort == key;
      final child = InkWell(
        onTap: key == null
            ? null
            : () => setState(() {
                  if (sort == key) {
                    asc = !asc;
                  } else {
                    sort = key;
                    asc = key == SortKey.name;
                  }
                }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Text(label, style: active ? style?.copyWith(fontWeight: FontWeight.w700) : style),
              if (active) Icon(asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14),
            ],
          ),
        ),
      );
      return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        const SizedBox(width: 34),
        h('名称', SortKey.name, flex: 5),
        h('分类', null, width: 110),
        h('大小', SortKey.size, width: 90, align: TextAlign.right),
        const SizedBox(width: 20),
        h('上传时间', SortKey.time, width: 130),
        h('来源', null, width: 110),
      ]),
    );
  }

  // --- mobile ---

  Widget _mobile(BuildContext context) {
    final all = items;
    final l = listing;
    final selecting = selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: selecting
            ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(selected.clear))
            : (l != null && l.path.length > 1 && results == null)
                ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => open(l.path[l.path.length - 2].id))
                : null,
        title: selecting
            ? Text('已选择 ${selected.length} 项')
            : Text(results != null ? '搜索' : (l == null ? '文件' : _folderName(l))),
        actions: selecting
            ? [
                IconButton(
                    icon: const Icon(Icons.download_rounded), onPressed: () => NodeActions.download(context, selectedNodes)),
                IconButton(
                    icon: const Icon(Icons.drive_file_move_rounded),
                    onPressed: () => NodeActions.move(context, selectedNodes)),
                IconButton(
                    icon: const Icon(Icons.label_rounded), onPressed: () => NodeActions.categorize(context, selectedNodes)),
                IconButton(
                    icon: const Icon(Icons.delete_rounded), onPressed: () => NodeActions.trash(context, selectedNodes)),
              ]
            : [
                IconButton(icon: const Icon(Icons.create_new_folder_outlined), onPressed: _newFolder),
                PopupMenuButton<SortKey>(
                  icon: const Icon(Icons.sort_rounded),
                  onSelected: (k) => setState(() {
                    if (sort == k) {
                      asc = !asc;
                    } else {
                      sort = k;
                      asc = k == SortKey.name;
                    }
                  }),
                  itemBuilder: (_) => [
                    for (final (k, label) in [(SortKey.name, '按名称'), (SortKey.time, '按上传时间'), (SortKey.size, '按大小')])
                      CheckedPopupMenuItem(value: k, checked: sort == k, child: Text(label)),
                  ],
                ),
              ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SearchBar(
              controller: searchCtrl,
              hintText: '搜索全部文件',
              leading: const Icon(Icons.search_rounded),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: _search,
              trailing: [
                if (searchCtrl.text.isNotEmpty)
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        searchCtrl.clear();
                        _search('');
                      }),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: l == null
          ? null
          : FloatingActionButton(
              onPressed: () => _uploadSheet(context, l),
              child: const Icon(Icons.add_rounded),
            ),
      body: PopScope(
        canPop: !(l != null && l.path.length > 1) && !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (selecting) {
            setState(selected.clear);
          } else if (l != null && l.path.length > 1) {
            open(l.path[l.path.length - 2].id);
          }
        },
        child: _body(context, all, (n) {
          final (icon, color) = nodeIcon(n);
          final cat = AppState.instance.categoryOf(n);
          final sel = selected.contains(n.id);
          return ListTile(
            selected: sel,
            selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            leading: sel ? const Icon(Icons.check_circle_rounded) : Icon(icon, color: color, size: 30),
            title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Row(children: [
              if (cat != null) ...[CategoryChip(cat), const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  results != null ? n.location : '${nodeSubtitle(n)} · ${formatTime(n.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            trailing: selecting
                ? null
                : IconButton(icon: const Icon(Icons.more_vert), onPressed: () => NodeActions.showSheet(context, n)),
            onTap: () {
              if (selecting) {
                setState(() => sel ? selected.remove(n.id) : selected.add(n.id));
              } else if (n.isDir) {
                open(n.id);
              } else {
                NodeActions.open(context, n);
              }
            },
            onLongPress: () => setState(() => selected.add(n.id)),
          );
        }),
      ),
    );
  }

  void _uploadSheet(BuildContext context, Listing l) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('照片和视频'),
            onTap: () {
              Navigator.pop(ctx);
              pickAndUpload(context, parentId: l.parent.id, destination: _folderName(l), type: FileType.media);
            },
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('文件'),
            onTap: () {
              Navigator.pop(ctx);
              pickAndUpload(context, parentId: l.parent.id, destination: _folderName(l));
            },
          ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                pickAndUpload(context, parentId: l.parent.id, destination: _folderName(l), folder: true);
              },
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('新建文件夹'),
            onTap: () {
              Navigator.pop(ctx);
              _newFolder();
            },
          ),
        ]),
      ),
    );
  }
}

class _CrumbButton extends StatelessWidget {
  const _CrumbButton({required this.crumb, required this.isRoot, required this.isLast});
  final Crumb crumb;
  final bool isRoot;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return NodeDropTarget(
      folderId: crumb.id,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: isLast ? cs.onSurface : cs.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: TextStyle(fontSize: 15, fontWeight: isLast ? FontWeight.w700 : FontWeight.w500),
        ),
        onPressed: isLast ? null : () => Nav.instance.openFolder(crumb.id),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (isRoot) ...[const Icon(Icons.home_rounded, size: 18), const SizedBox(width: 4)],
          Text(isRoot ? '全部文件' : crumb.name, style: isLast ? TextStyle(color: cs.onSurface) : null),
        ]),
      ),
    );
  }
}

/// Accepts nodes dragged inside the app and moves them into [folderId].
class NodeDropTarget extends StatelessWidget {
  const NodeDropTarget({super.key, required this.folderId, required this.child, this.radius = 8});
  final String folderId;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DragTarget<List<Node>>(
      onWillAcceptWithDetails: (d) => d.data.every((n) => n.id != folderId && n.parentId != folderId),
      onAcceptWithDetails: (d) => NodeActions.moveTo(context, d.data, folderId),
      builder: (ctx, cand, _) => Container(
        decoration: cand.isEmpty
            ? null
            : BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(radius),
              ),
        child: child,
      ),
    );
  }
}

class _DesktopRow extends StatelessWidget {
  const _DesktopRow({
    required this.node,
    required this.selected,
    required this.showLocation,
    required this.dragNodes,
    required this.onTap,
    required this.onSecondary,
  });

  final Node node;
  final bool selected;
  final bool showLocation;
  final List<Node> Function() dragNodes;
  final VoidCallback onTap;
  final void Function(Offset) onSecondary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final n = node;
    final (icon, color) = nodeIcon(n);
    final cat = AppState.instance.categoryOf(n);
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    Widget row = Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer.withValues(alpha: 0.7) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium),
            if (showLocation && n.location.isNotEmpty)
              Text(n.location, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted?.copyWith(fontSize: 11)),
          ]),
        ),
        SizedBox(width: 110, child: Align(alignment: Alignment.centerLeft, child: cat == null ? null : CategoryChip(cat))),
        SizedBox(width: 90, child: Text(nodeSubtitle(n), textAlign: TextAlign.right, style: muted)),
        const SizedBox(width: 20),
        SizedBox(width: 130, child: Text(formatTime(n.createdAt), style: muted)),
        SizedBox(
            width: 110,
            child: Text(n.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted)),
      ]),
    );
    row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      child: row,
    );
    if (n.isDir) row = NodeDropTarget(folderId: n.id, child: row);
    return Draggable<List<Node>>(
      data: dragNodes(),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(nodes: dragNodes()),
      child: row,
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.nodes});
  final List<Node> nodes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = nodeIcon(nodes.first);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(nodes.length == 1 ? nodes.first.name : '${nodes.first.name} 等 ${nodes.length} 项'),
        ]),
      ),
    );
  }
}

/// Collapsible folder tree for the desktop files view.
class FolderTree extends StatefulWidget {
  const FolderTree({super.key, required this.currentPath});
  final List<Crumb> currentPath;

  @override
  State<FolderTree> createState() => _FolderTreeState();
}

class _FolderTreeState extends State<FolderTree> {
  String? rootId;
  final children = <String, List<Node>>{};
  final expanded = <String>{};
  final loadingIds = <String>{};
  StreamSubscription<ServerEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadChildren(null);
    _sub = AppState.instance.events.listen((ev) {
      if (ev.type == 'hello') {
        for (final id in expanded.toList()) {
          _loadChildren(id);
        }
        return;
      }
      if (!(ev.node?.isDir ?? false)) return;
      for (final id in {ev.parentId, ev.oldParentId}) {
        if (id.isNotEmpty && children.containsKey(id)) _loadChildren(id);
      }
    });
  }

  @override
  void didUpdateWidget(FolderTree old) {
    super.didUpdateWidget(old);
    final ids = widget.currentPath.map((c) => c.id).toList();
    for (final id in ids.take(ids.length > 1 ? ids.length - 1 : ids.length)) {
      if (expanded.add(id) && !children.containsKey(id)) _loadChildren(id);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadChildren(String? id) async {
    final api = AppState.instance.api;
    if (api == null || (id != null && loadingIds.contains(id))) return;
    if (id != null) loadingIds.add(id);
    try {
      final l = await api.list(id, dirsOnly: true);
      if (!mounted) return;
      setState(() {
        if (id == null) {
          rootId = l.parent.id;
          expanded.add(l.parent.id);
        }
        children[l.parent.id] = l.children;
      });
    } catch (_) {
    } finally {
      if (id != null) loadingIds.remove(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = rootId;
    if (root == null) return const SizedBox();
    final current = widget.currentPath.isEmpty ? root : widget.currentPath.last.id;
    final rows = <Widget>[];
    void add(String id, String name, int depth, bool maybeHasChildren) {
      final isOpen = expanded.contains(id);
      rows.add(_TreeRow(
        id: id,
        name: name,
        depth: depth,
        isRoot: id == root,
        open: isOpen,
        current: id == current,
        showArrow: maybeHasChildren && (children[id]?.isNotEmpty ?? true),
        onToggle: () => setState(() {
          if (!expanded.remove(id)) {
            expanded.add(id);
            if (!children.containsKey(id)) _loadChildren(id);
          }
        }),
      ));
      if (isOpen) {
        for (final c in children[id] ?? const <Node>[]) {
          add(c.id, c.name, depth + 1, c.childCount > 0);
        }
      }
    }

    add(root, '全部文件', 0, true);
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6), children: rows);
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.id,
    required this.name,
    required this.depth,
    required this.isRoot,
    required this.open,
    required this.current,
    required this.showArrow,
    required this.onToggle,
  });

  final String id;
  final String name;
  final int depth;
  final bool isRoot;
  final bool open;
  final bool current;
  final bool showArrow;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return NodeDropTarget(
      folderId: id,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Nav.instance.openFolder(isRoot ? null : id),
        child: Container(
          height: 32,
          padding: EdgeInsets.only(left: 4.0 + depth * 14),
          decoration: BoxDecoration(
            color: current ? cs.secondaryContainer : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            SizedBox(
              width: 22,
              child: showArrow
                  ? InkWell(
                      onTap: onToggle,
                      child: Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 18),
                    )
                  : null,
            ),
            Icon(isRoot ? Icons.home_rounded : (open ? Icons.folder_open_rounded : Icons.folder_rounded),
                size: 18, color: isRoot ? cs.primary : const Color(0xFF5B8DEF)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: current ? FontWeight.w600 : FontWeight.normal)),
            ),
          ]),
        ),
      ),
    );
  }
}
