import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/transfers.dart';
import '../platform/shell.dart';
import 'dialogs.dart';
import 'format.dart';
import 'files_view.dart';
import 'node_actions.dart';
import 'settings_view.dart';
import 'timeline_view.dart';
import 'transfers_view.dart';
import 'trash_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<String>? _notices;

  @override
  void initState() {
    super.initState();
    Shell.instance.onShowTransfers = () => Nav.instance.go(Section.transfers);
    _notices = AppState.instance.notices.listen((m) {
      if (mounted) toast(context, m);
    });
  }

  @override
  void dispose() {
    _notices?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MediaQuery.sizeOf(context).width >= 700 ? const _DesktopHome() : const _MobileHome();
  }
}

class _DesktopHome extends StatelessWidget {
  const _DesktopHome();

  @override
  Widget build(BuildContext context) {
    final nav = Nav.instance;
    return Scaffold(
      body: Row(children: [
        const SizedBox(width: 240, child: Sidebar()),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(children: [
            const _OfflineBar(),
            Expanded(
              child: ListenableBuilder(
                listenable: nav,
                builder: (context, _) => switch (nav.section) {
                  Section.files || Section.categories => const FilesView(),
                  Section.timeline => const TimelineView(),
                  Section.category => CategoryView(key: ValueKey(nav.categoryId), categoryId: nav.categoryId ?? ''),
                  Section.trash => const TrashView(),
                  Section.transfers => const TransfersView(),
                  Section.settings => const SettingsView(),
                },
              ),
            ),
            const _TransferBar(),
          ]),
        ),
      ]),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar();

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        Widget bar(IconData icon, String text, Color bg, Color fg, {Widget? action}) => Material(
              color: bg,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text, style: TextStyle(color: fg))),
                  ?action,
                ]),
              ),
            );
        if (!s.online) {
          return bar(Icons.cloud_off_rounded, s.viaRelay ? '无法连接到中转站，正在自动重连…' : '无法连接到交换站，正在自动重连…',
              cs.errorContainer, cs.onErrorContainer,
              action: TextButton(onPressed: s.reconnectNow, child: const Text('立即重试')));
        }
        final seen = s.relay?.nasSeen;
        if (s.viaRelay && (seen == null || DateTime.now().difference(seen) > const Duration(minutes: 5))) {
          return bar(
              Icons.schedule_rounded,
              seen == null ? 'NAS 尚未连接中转站：可以浏览，但新的操作要等 NAS 上线后才会执行' : 'NAS 已 ${formatAgo(seen).replaceAll('前', '')}未同步（可能离线）：操作会在它上线后执行',
              cs.tertiaryContainer,
              cs.onTertiaryContainer);
        }
        return const SizedBox();
      },
    );
  }
}

/// Where the connection goes, for the sidebar and settings.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final r = s.relay;
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11);
    final parts = <String>[
      s.api?.modeLabel ?? '',
      if (r != null && r.nasSeen != null) 'NAS ${formatAgo(r.nasSeen!)}同步',
      if (r != null && r.pendingOps > 0) '${r.pendingOps} 项待同步',
    ];
    return Tooltip(
      message: s.viaRelay ? '经公网中转站，内容端到端加密，中转站无法读取' : '与 NAS 在同一网络中直接连接',
      child: Row(children: [
        Icon(s.viaRelay ? Icons.cloud_sync_rounded : Icons.lan_rounded, size: 12, color: cs.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(child: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
      ]),
    );
  }
}

class _TransferBar extends StatelessWidget {
  const _TransferBar();

  @override
  Widget build(BuildContext context) {
    final tm = TransferManager.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([tm, Nav.instance]),
      builder: (context, _) {
        final active = tm.items.where((t) => t.active).toList();
        if (active.isEmpty || Nav.instance.section == Section.transfers) return const SizedBox();
        final total = active.fold<int>(0, (s, t) => s + t.totalBytes);
        final done = active.fold<int>(0, (s, t) => s + t.doneBytes);
        final speed = active.fold<double>(0, (s, t) => s + t.speed);
        final cs = Theme.of(context).colorScheme;
        return Material(
          color: cs.surfaceContainer,
          child: InkWell(
            onTap: () => Nav.instance.go(Section.transfers),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text('${active.length} 项传输中'),
                const SizedBox(width: 16),
                Expanded(
                  child: LinearProgressIndicator(
                      value: total == 0 ? null : done / total, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 16),
                Text(total == 0 ? '' : '${(done * 100 / total).floor()}%  ${speed > 0 ? '${(speed / 1048576).toStringAsFixed(1)} MB/s' : ''}'),
                const Icon(Icons.chevron_right_rounded),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final nav = Nav.instance;
    final tm = TransferManager.instance;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, nav, tm]),
        builder: (context, _) {
          Widget item(IconData icon, String label, Section sec, {int badge = 0}) => _NavTile(
                icon: icon,
                label: label,
                selected: nav.section == sec || (sec == Section.files && nav.section == Section.categories),
                badge: badge,
                onTap: () => sec == Section.files ? nav.openFolder(nav.folderId) : nav.go(sec),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 6, 10),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF4F7CFF), Color(0xFF7B5CFF)]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.info?.name ?? s.profile?.name ?? 'FileSwitch',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Row(children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(color: s.online ? Colors.green : cs.error, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(s.user?.username ?? s.profile?.username ?? '',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ]),
                    const ConnectionBadge(),
                  ]),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (v) async {
                    if (v == 'switch') await s.detach();
                    if (v == 'logout' &&
                        context.mounted &&
                        await confirm(context, '退出登录', '本机的授权将被撤销，下次需要重新输入密码。', ok: '退出登录')) {
                      await s.signOut();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'switch', child: Text('切换服务器')),
                    PopupMenuItem(value: 'logout', child: Text('退出登录')),
                  ],
                ),
              ]),
            ),
            item(Icons.folder_copy_rounded, '全部文件', Section.files),
            item(Icons.history_rounded, '时间线', Section.timeline),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 2),
              child: Row(children: [
                Text('分类', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.outline)),
                const Spacer(),
                IconButton(
                  tooltip: '新建分类',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  onPressed: () => createCategoryFlow(context),
                ),
              ]),
            ),
            Expanded(
              child: ListView(padding: EdgeInsets.zero, children: [
                for (final c in s.categories) _CategoryTile(c: c, selected: nav.section == Section.category && nav.categoryId == c.id),
                if (s.categories.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Text('新建分类后，可以把文件直接拖到分类上，或拖到菜单栏图标附近投递。',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ]),
            ),
            const Divider(height: 1),
            const SizedBox(height: 6),
            item(Icons.swap_vert_rounded, '传输', Section.transfers, badge: tm.activeCount),
            item(Icons.delete_outline_rounded, '回收站', Section.trash),
            item(Icons.security_rounded, '设备与安全', Section.settings),
            const SizedBox(height: 10),
          ]);
        },
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap, this.badge = 0, this.leading});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Row(children: [
              const SizedBox(width: 12),
              SizedBox(width: 22, child: Center(child: leading ?? Icon(icon, size: 20, color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant))),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
              ),
              if (badge > 0)
                Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: TextStyle(color: cs.onPrimary, fontSize: 11)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A category in the sidebar. Files dragged from the OS upload into it; nodes
/// dragged from the file list get tagged with it.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.c, required this.selected});
  final Category c;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onSecondaryTapDown: (d) async {
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
        final v = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(d.globalPosition & const Size(1, 1), Offset.zero & overlay.size),
          items: const [
            PopupMenuItem(value: 'upload', child: Text('上传文件到此分类…')),
            PopupMenuItem(value: 'edit', child: Text('编辑分类')),
            PopupMenuItem(value: 'delete', child: Text('删除分类', style: TextStyle(color: Colors.red))),
          ],
        );
        if (!context.mounted) return;
        switch (v) {
          case 'upload':
            pickAndUpload(context, categoryId: c.id, destination: c.name);
          case 'edit':
            editCategoryFlow(context, c);
          case 'delete':
            deleteCategoryFlow(context, c);
        }
      },
      child: DragTarget<List<Node>>(
        onAcceptWithDetails: (d) => NodeActions.setCategory(context, d.data, c.id),
        builder: (ctx, cand, _) => Container(
          decoration: cand.isEmpty
              ? null
              : BoxDecoration(color: c.color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
          child: _NavTile(
            icon: Icons.label,
            leading: CategoryDot(c),
            label: c.name,
            selected: selected,
            badge: 0,
            onTap: () => Nav.instance.go(Section.category, categoryId: c.id),
          ),
        ),
      ),
    );
    return OsDropZone(
      label: '投递到「${c.name}」',
      radius: 10,
      onDrop: (paths) {
        TransferManager.instance.upload(paths, categoryId: c.id, destination: c.name);
        toast(context, '已开始上传 ${paths.length} 项到「${c.name}」');
      },
      child: Stack(children: [
        tile,
        Positioned(
          right: 18,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Center(child: Text('${c.count}', style: Theme.of(context).textTheme.bodySmall)),
          ),
        ),
      ]),
    );
  }
}

class _MobileHome extends StatefulWidget {
  const _MobileHome();

  @override
  State<_MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<_MobileHome> {
  final nav = Nav.instance;

  static const _tabs = [Section.files, Section.timeline, Section.categories, Section.transfers, Section.settings];

  @override
  void initState() {
    super.initState();
    nav.addListener(_onNav);
  }

  @override
  void dispose() {
    nav.removeListener(_onNav);
    super.dispose();
  }

  String? _shownCategory;

  void _onNav() {
    if (nav.section == Section.category && nav.categoryId != null) {
      if (_shownCategory == nav.categoryId) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      final id = _shownCategory = nav.categoryId;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryView(categoryId: id!))).then((_) {
        if (_shownCategory == id) _shownCategory = null;
        if (nav.section == Section.category && nav.categoryId == id) nav.go(Section.categories);
      });
    } else {
      // e.g. "show in folder" from a pushed page: close it and switch tabs
      _shownCategory = null;
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var index = _tabs.indexOf(nav.section);
    if (index < 0) index = nav.section == Section.category ? 2 : 0;
    final tm = TransferManager.instance;
    return Scaffold(
      body: Column(children: [
        Expanded(
          child: IndexedStack(index: index, children: const [
            FilesView(),
            TimelineView(),
            CategoriesPage(),
            TransfersView(),
            SettingsView(),
          ]),
        ),
        const _OfflineBar(),
      ]),
      bottomNavigationBar: ListenableBuilder(
        listenable: tm,
        builder: (context, _) => NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => nav.go(_tabs[i]),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.folder_copy_outlined), selectedIcon: Icon(Icons.folder_copy_rounded), label: '文件'),
            const NavigationDestination(icon: Icon(Icons.history_rounded), label: '时间线'),
            const NavigationDestination(icon: Icon(Icons.label_outline_rounded), selectedIcon: Icon(Icons.label_rounded), label: '分类'),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: tm.activeCount > 0,
                label: Text('${tm.activeCount}'),
                child: const Icon(Icons.swap_vert_rounded),
              ),
              label: '传输',
            ),
            const NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: '我的'),
          ],
        ),
      ),
    );
  }
}
