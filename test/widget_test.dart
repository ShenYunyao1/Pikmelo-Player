import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/main.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:flutter/services.dart';

void main() {
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
