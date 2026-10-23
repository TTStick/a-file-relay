import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import 'format.dart';

void toast(BuildContext context, String msg, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(msg), action: action, behavior: SnackBarBehavior.floating, width: isDesktop ? 420 : null));
}

void showError(BuildContext context, Object e) => toast(context, e is ApiException ? e.message : '$e');

Future<bool> confirm(BuildContext context, String title, String message,
    {String ok = '确定', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> textInput(BuildContext context, String title,
    {String initial = '', String label = '', String ok = '确定', bool selectBaseName = false, bool obscure = false}) {
  final ctrl = TextEditingController(text: initial);
  if (selectBaseName) {
    final dot = initial.lastIndexOf('.');
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
  } else {
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  }
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: obscure,
          decoration: InputDecoration(labelText: label.isEmpty ? null : label),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

/// Result of the category picker: null id = remove category.
class CategoryChoice {
  const CategoryChoice(this.id);
  final String? id;
}

Future<CategoryChoice?> pickCategory(BuildContext context, {String current = ''}) {
  final cats = AppState.instance.categories;
  return showDialog<CategoryChoice>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('设置分类'),
      children: [
        for (final c in cats)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CategoryChoice(c.id)),
            child: Row(children: [
              CategoryDot(c),
              const SizedBox(width: 12),
              Expanded(child: Text(c.name)),
              if (c.id == current) const Icon(Icons.check, size: 18),
            ]),
          ),
        if (cats.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('还没有分类，可在侧边栏「分类」处新建。')),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, const CategoryChoice(null)),
          child: const Row(children: [Icon(Icons.label_off_outlined, size: 18), SizedBox(width: 12), Text('移除分类')]),
        ),
      ],
    ),
  );
}

class CategoryDot extends StatelessWidget {
  const CategoryDot(this.c, {super.key, this.size = 12});
  final Category c;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (c.icon.isNotEmpty) {
      return SizedBox(width: size + 6, child: Text(c.icon, style: TextStyle(fontSize: size + 2), textAlign: TextAlign.center));
    }
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.color, shape: BoxShape.circle),
    );
  }
}

class CategoryChip extends StatelessWidget {
  const CategoryChip(this.c, {super.key});
  final Category c;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? Color.lerp(c.color, Colors.white, 0.45)! : c.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.color.withValues(alpha: dark ? 0.24 : 0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (c.icon.isNotEmpty) ...[Text(c.icon, style: const TextStyle(fontSize: 11)), const SizedBox(width: 3)],
        Text(c.name,
            style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// Create or edit a category. Returns (name, colorHex, icon).
Future<(String, String, String)?> editCategory(BuildContext context, {Category? existing}) {
  final name = TextEditingController(text: existing?.name ?? '');
  final icon = TextEditingController(text: existing?.icon ?? '');
  var color = existing?.color ?? categoryPalette[AppState.instance.categories.length % categoryPalette.length];
  String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  return showDialog<(String, String, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        scrollable: true,
        title: Text(existing == null ? '新建分类' : '编辑分类'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: '名称', hintText: '如：照片、工作、临时')),
            const SizedBox(height: 12),
            TextField(
                controller: icon,
                maxLength: 2,
                decoration: const InputDecoration(labelText: '图标（可选，填一个 emoji）', counterText: '')),
            const SizedBox(height: 16),
            const Text('颜色'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in categoryPalette)
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() => color = c),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: c.toARGB32() == color.toARGB32() ? Theme.of(ctx).colorScheme.onSurface : Colors.transparent,
                          width: 2.5),
                    ),
                  ),
                ),
            ]),
            if (existing == null) ...[
              const SizedBox(height: 16),
              Text('投递到该分类的文件会放进根目录下的同名文件夹，并打上分类标签。',
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(ctx, (name.text.trim(), hex(color), icon.text.trim()));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

/// Lets the user browse to a folder. Returns its id.
Future<String?> pickFolder(BuildContext context, {String title = '移动到', Set<String> exclude = const {}}) {
  return showDialog<String>(context: context, builder: (ctx) => _FolderPicker(title: title, exclude: exclude));
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.title, required this.exclude});
  final String title;
  final Set<String> exclude;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  Listing? listing;
  String? error;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? id) async {
    setState(() => error = null);
    try {
      final l = await AppState.instance.api!.list(id, dirsOnly: true);
      if (mounted) setState(() => listing = l);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = listing;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(children: [
          if (l != null)
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (var i = 0; i < l.path.length; i++) ...[
                  if (i > 0) const Icon(Icons.chevron_right, size: 16),
                  TextButton(
                    onPressed: () => _load(l.path[i].id),
                    child: Text(i == 0 ? '全部文件' : l.path[i].name),
                  ),
                ],
              ]),
            ),
          const Divider(height: 1),
          Expanded(
            child: error != null
                ? Center(child: Text(error!))
                : l == null
                    ? const Center(child: CircularProgressIndicator())
                    : l.children.isEmpty
                        ? const Center(child: Text('没有子文件夹'))
                        : ListView(children: [
                            for (final c in l.children)
                              ListTile(
                                enabled: !widget.exclude.contains(c.id),
                                leading: const Icon(Icons.folder_rounded, color: Color(0xFF5B8DEF)),
                                title: Text(c.name),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _load(c.id),
                              ),
                          ]),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: l == null
              ? null
              : () async {
                  final name = await textInput(context, '新建文件夹', label: '名称');
                  if (name == null || name.isEmpty) return;
                  try {
                    await AppState.instance.api!.createFolder(parentId: l.parent.id, name: name);
                    _load(l.parent.id);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
          child: const Text('新建文件夹'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: l == null || widget.exclude.contains(l.parent.id) ? null : () => Navigator.pop(context, l.parent.id),
          child: const Text('选择此处'),
        ),
      ],
    );
  }
}
