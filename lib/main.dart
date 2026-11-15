import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/pikmelo_app.dart';
import 'shared/diagnostics.dart';
import 'shared/app_log.dart';
import 'app/app_dependencies.dart';

export 'app/pikmelo_app.dart' show PikmeloPlayerApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.initialize();
  AppLog.instance.info('app.start');
  final onFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.instance.error('flutter.error', {
      'type': details.exception.runtimeType,
      'message': details.exceptionAsString(),
      'stack': details.stack?.toString(),
      'library': details.library,
    });
    onFlutterError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.error('app.unhandled', {
      'type': error.runtimeType,
      'stack': stack.toString(),
    });
    return false;
  };
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
