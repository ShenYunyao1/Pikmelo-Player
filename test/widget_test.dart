import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/main.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:flutter/services.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';

void main() {
  testWidgets('playback settings persist mode and the startup restore switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dependencies = AppDependencies(
      enableUpdates: false,
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: _Keys(),
      openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
    );
    await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('应用音量 100%'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(DropdownButton<PlaybackMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单曲循环').last);
    await tester.pumpAndSettle();
    expect(dependencies.playback.mode, PlaybackMode.repeatOne);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    final store = await dependencies.openStore();
    expect(store.setting('restore_playback_session'), 'false');
    expect(store.setting('playback_preferences'), contains('repeatOne'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final closing = dependencies.dispose();
    await tester.pump();
    await closing;
  });

  testWidgets('keyboard playback leaves text fields available for editing', (
    tester,
  ) async {
    final dependencies = AppDependencies(
      enableUpdates: false,
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: _Keys(),
      openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
    );
    await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    final before = dependencies.playback.transportRevision;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(dependencies.playback.transportRevision, before);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(dependencies.playback.transportRevision, greaterThan(before));
    await tester.pumpWidget(const SizedBox.shrink());
    final closing = dependencies.dispose();
    await tester.pump();
    await closing;
  });
  testWidgets('home page lays out at phone and desktop sizes', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const PikmeloPlayerApp());
    await tester.pumpAndSettle();

    expect(find.text('曲库'), findsWidgets);
    expect(find.text('连接音乐库'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 360);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}

class _Keys extends ApiKeyStore {
  @override
  Future<String?> read(String serverKey) async => null;
}
