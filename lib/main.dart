import 'package:flutter/material.dart';

import 'app/pikmelo_app.dart';
import 'shared/diagnostics.dart';
import 'app/app_dependencies.dart';

export 'app/pikmelo_app.dart' show PikmeloPlayerApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Diagnostics.event('app.start');
  Diagnostics.watchFrames();
  final dependencies = AppDependencies();
  try {
    await dependencies.initializePlatformPlayback();
  } catch (error) {
    debugPrint('System media initialization failed: $error');
    dependencies.playback.reportSystemError('系统媒体控制初始化失败，请重启应用后重试。');
  }
  runApp(PikmeloPlayerApp(dependencies: dependencies));
}
