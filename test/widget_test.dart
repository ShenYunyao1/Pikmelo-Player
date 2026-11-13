import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/main.dart';
import 'package:pikmelo_player/settings/ui/settings_view.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:flutter/services.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';

void main() {
  testWidgets('settings group navigation retains server drafts', (
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
    for (final label in ['服务器配置', '下载行为', '播放行为', '关于']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('服务器配置'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'https://draft.example.com',
    );
    await tester.tap(find.byTooltip('返回设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务器配置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'https://draft.example.com',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('下载行为'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final closing = dependencies.dispose();
    await tester.pump();
    await closing;
  });

  testWidgets('search clear retains the downloaded filter and input focus', (
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
    await tester.tap(find.widgetWithText(ChoiceChip, '已下载'));
    await tester.enterText(find.byType(TextField), 'query');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已下载'))
          .selected,
      isTrue,
    );
    expect(find.byTooltip('清除搜索'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final closing = dependencies.dispose();
    await tester.pump();
    await closing;
  });

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
    await tester.tap(find.text('播放行为'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('默认播放模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单曲循环').last);
    await tester.pumpAndSettle();
    expect(dependencies.playback.defaultMode, PlaybackMode.repeatOne);
    expect(dependencies.playback.mode, PlaybackMode.sequence);
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
    await tester.tap(find.text('服务器配置'));
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
  testWidgets(
    'all settings sections fit phone landscape desktop and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final dependencies = AppDependencies(
        enableUpdates: false,
        keyStore: _Keys(),
        networkReader: () async => {'connected': true, 'cellular': false},
        openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
      );
      await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      for (final size in [
        const Size(320, 640),
        const Size(640, 360),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        for (final section in ['服务器配置', '下载行为', '播放行为', '关于']) {
          final scrollable = find
              .descendant(
                of: find.byType(SettingsView),
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pump();
          await tester.scrollUntilVisible(
            find.text(section),
            120,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(section));
          await tester.pumpAndSettle();
          expect(find.byTooltip('返回设置'), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (section == '下载行为') {
            await tester.ensureVisible(find.text('曲目移动网络行为'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('曲目移动网络行为'));
            await tester.pumpAndSettle();
            expect(find.text('允许下载'), findsOneWidget);
            expect(find.text('禁止下载'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('仅播放前下载').last);
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('返回设置'));
          await tester.pumpAndSettle();
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = dependencies.dispose();
      await tester.pump();
      await closing;
    },
  );

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
