import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../library/ui/library_page.dart';
import '../settings/connection_controller.dart';
import 'app_dependencies.dart';

class PikmeloPlayerApp extends StatefulWidget {
  const PikmeloPlayerApp({super.key, this.dependencies});

  final AppDependencies? dependencies;

  @override
  State<PikmeloPlayerApp> createState() => _PikmeloPlayerAppState();
}

class _PikmeloPlayerAppState extends State<PikmeloPlayerApp>
    with WidgetsBindingObserver {
  late final AppDependencies _dependencies;
  late final ConnectionController _connection;
  late final bool _ownsDependencies;

  @override
  void initState() {
    super.initState();
    _ownsDependencies = widget.dependencies == null;
    _dependencies = widget.dependencies ?? AppDependencies();
    _connection = _dependencies.createConnectionController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_connection.refresh());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final context = FocusManager.instance.primaryFocus?.context;
    if (context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final player = _dependencies.playback;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(player.toggle());
    } else if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(player.next());
    } else if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(player.previous());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connection.dispose();
    if (_ownsDependencies) unawaited(_dependencies.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF92DFC0);
    return MaterialApp(
      title: 'Pikmelo Player',
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          Focus(canRequestFocus: false, onKeyEvent: _onKey, child: child!),
      theme: ThemeData(
        fontFamily: defaultTargetPlatform == TargetPlatform.windows
            ? 'Microsoft YaHei'
            : null,
        fontFamilyFallback: const ['Noto Sans CJK SC', 'sans-serif'],
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
              surface: const Color(0xFF101B18),
            ).copyWith(
              primary: seed,
              onPrimary: const Color(0xFF10382A),
              onSurface: const Color(0xFFF4F2EA),
              onSurfaceVariant: const Color(0xFF9AAEA3),
              surfaceContainer: const Color(0xFF1B2924),
            ),
        scaffoldBackgroundColor: const Color(0xFF101B18),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFF1B2924),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B2924),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101B18),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: LibraryPage(controller: _connection),
    );
  }
}
