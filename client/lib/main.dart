import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'platform/shell.dart';
import 'ui/app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final s = AppState.instance;
  await s.loadConfig();
  await Shell.instance.init(startHidden: args.contains('--hidden') || s.config.startHidden);
  runApp(const FileSwitchApp());
  await s.init();
}
