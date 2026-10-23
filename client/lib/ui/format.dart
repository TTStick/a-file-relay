import 'package:flutter/material.dart';

import '../core/models.dart';

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String two(int n) => n.toString().padLeft(2, '0');

String formatTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (d == today) return '今天 $hm';
  if (d == today.subtract(const Duration(days: 1))) return '昨天 $hm';
  if (t.year == now.year) return '${t.month}月${t.day}日 $hm';
  return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
}

String formatDay(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  if (d == today) return '今天';
  if (d == today.subtract(const Duration(days: 1))) return '昨天';
  final w = weekdays[t.weekday - 1];
  if (t.year == now.year) return '${t.month}月${t.day}日 $w';
  return '${t.year}年${t.month}月${t.day}日 $w';
}

String formatAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 2) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return formatTime(t);
}

String formatSpeed(double bps) => bps <= 0 ? '' : '${formatBytes(bps.round())}/s';

String nodeSubtitle(Node n) => n.isDir ? '${n.childCount} 项' : formatBytes(n.size);

(IconData, Color) nodeIcon(Node n) {
  if (n.isDir) return (Icons.folder_rounded, const Color(0xFF5B8DEF));
  switch (n.ext) {
    case 'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'bmp' || 'heic' || 'svg' || 'tiff':
      return (Icons.image_rounded, const Color(0xFF2EAD6B));
    case 'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' || 'm4v':
      return (Icons.movie_rounded, const Color(0xFFE5534B));
    case 'mp3' || 'flac' || 'wav' || 'aac' || 'm4a' || 'ogg':
      return (Icons.music_note_rounded, const Color(0xFFB45FD8));
    case 'pdf':
      return (Icons.picture_as_pdf_rounded, const Color(0xFFD64541));
    case 'doc' || 'docx' || 'pages' || 'rtf':
      return (Icons.description_rounded, const Color(0xFF2B6CD4));
    case 'xls' || 'xlsx' || 'numbers' || 'csv':
      return (Icons.table_chart_rounded, const Color(0xFF1E8E4E));
    case 'ppt' || 'pptx' || 'key':
      return (Icons.slideshow_rounded, const Color(0xFFE07B24));
    case 'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'tgz' || 'xz' || 'dmg' || 'iso':
      return (Icons.inventory_2_rounded, const Color(0xFF8D6E4F));
    case 'apk' || 'exe' || 'msi' || 'pkg' || 'ipa' || 'app':
      return (Icons.apps_rounded, const Color(0xFF546E7A));
    case 'txt' || 'md' || 'log':
      return (Icons.article_rounded, const Color(0xFF607D8B));
    case 'go' || 'dart' || 'js' || 'ts' || 'py' || 'java' || 'kt' || 'swift' || 'c' || 'cpp' || 'h' || 'rs' ||
          'json' || 'yaml' || 'yml' || 'xml' || 'html' || 'css' || 'sh':
      return (Icons.code_rounded, const Color(0xFF455A64));
  }
  return (Icons.insert_drive_file_rounded, const Color(0xFF78909C));
}

const categoryPalette = <Color>[
  Color(0xFF4F7CFF),
  Color(0xFF2EAD6B),
  Color(0xFFF59E0B),
  Color(0xFFE5534B),
  Color(0xFFB45FD8),
  Color(0xFF14B8A6),
  Color(0xFFEC4899),
  Color(0xFF64748B),
  Color(0xFF8D6E4F),
  Color(0xFF0EA5E9),
];

String platformLabel(String p) => switch (p) {
      'macos' => 'macOS',
      'windows' => 'Windows',
      'android' => 'Android',
      'ios' => 'iOS',
      'linux' => 'Linux',
      _ => p.isEmpty ? '未知' : p,
    };

IconData platformIcon(String p) => switch (p) {
      'macos' => Icons.laptop_mac_rounded,
      'windows' => Icons.laptop_windows_rounded,
      'android' => Icons.phone_android_rounded,
      'ios' => Icons.phone_iphone_rounded,
      _ => Icons.devices_other_rounded,
    };

String auditLabel(String action) => switch (action) {
      'login' => '登录',
      'login_failed' => '登录失败',
      'logout' => '退出登录',
      'password_changed' => '修改密码',
      'password_reset' => '重置密码',
      'device_revoked' => '撤销设备授权',
      'trash_purged' => '彻底删除',
      'trash_emptied' => '清空回收站',
      'user_created' => '创建用户',
      'user_deleted' => '删除用户',
      _ => action,
    };
