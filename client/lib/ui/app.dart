import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/app_state.dart';
import '../platform/shell.dart';
import 'connect_screen.dart';
import 'home_screen.dart';
import 'mini_panel.dart';

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4F7CFF), brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 0),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 12)),
  );
}

class FileSwitchApp extends StatelessWidget {
  const FileSwitchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSwitch',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  late final AppLifecycleListener _life;
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: AppState.instance.reconnectNow);
    try {
      _links = AppLinks().uriLinkStream.listen(AppState.instance.openPairLink, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _life.dispose();
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([s, Shell.instance.miniMode]),
      builder: (context, _) {
        if (Shell.instance.miniMode.value) return const MiniPanel();
        if (!s.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        if (!s.signedIn) return const ConnectScreen();
        return const HomeScreen();
      },
    );
  }
}
