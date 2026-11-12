import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/app/pikmelo_app.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/ui/player_bar.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const systemControls = bool.fromEnvironment('PIKMELO_TEST_SYSTEM_CONTROLS');
  const captureDirectory = String.fromEnvironment('PIKMELO_UI_CAPTURE_DIR');
  final captureKey = GlobalKey();

  testWidgets(
    'downloaded audio plays offline after app recreation and releases before deletion',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'pikmelo-playback-',
      );
      final database = '${directory.path}/library.sqlite';
      final media = File('${directory.path}/track.media');
      const source = String.fromEnvironment('PIKMELO_TEST_MEDIA_PATH');
      if (source.isEmpty) {
        await media.writeAsBytes(_wave(seconds: systemControls ? 120 : 4));
      } else {
        await File(source).copy(media.path);
      }
      final uri = Uri.parse('https://offline-test.invalid');
      final size = await media.length();
      final track = {'id': 'offline-track', 'title': '离线播放测试曲目', 'size': size};
      final store = await LocalLibraryStore.open(databasePath: database);
      store.saveSelectedServer(uri);
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [track],
          playlists: [
            {
              'id': 'offline-list',
              'name': '离线播放测试歌单',
              'track_ids': ['offline-track', 'offline-track'],
            },
          ],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'offline',
          hasMore: false,
          fullSnapshot: true,
          reset: false,
          revision: 1,
        ),
      ]);
      store.saveOfflineMedia(
        serverUri: uri,
        expectedGeneration: store.generationFor(uri),
        trackId: 'offline-track',
        track: track,
        file: media,
      );
      store.close();
      AppDependencies createDependencies() => AppDependencies(
        enableUpdates: false,
        keyStore: _Keys(),
        openStore: () => LocalLibraryStore.open(databasePath: database),
        createClient: (connection, key) => _OfflineClient(connection.uri, key),
      );
      var dependencies = createDependencies();
      try {
        for (var launch = 0; launch < 2; launch++) {
          if (launch > 0) dependencies = createDependencies();
          await dependencies.initializePlatformPlayback();
          await dependencies.playback.setVolume(0);
          await tester.pumpWidget(
            RepaintBoundary(
              key: captureKey,
              child: PikmeloPlayerApp(dependencies: dependencies),
            ),
          );
          await _until(
            tester,
            () => find.text('离线 · 显示本地曲库').evaluate().isNotEmpty,
          );
          await tester.ensureVisible(find.text('离线播放测试歌单'));
          await tester.pumpAndSettle();
          if (launch == 0 && captureDirectory.isNotEmpty) {
            await _capture(captureKey, captureDirectory, 'library');
          }
          await tester.tap(find.text('离线播放测试歌单'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('离线播放测试曲目').first);
          await _until(
            tester,
            () =>
                dependencies.playback.state.position.inMilliseconds > 150 &&
                dependencies.playback.state.duration > Duration.zero,
          );
          expect(dependencies.playback.state.error, isNull);
          expect(dependencies.playback.queue.length, 2);
          await tester.tap(
            find
                .descendant(
                  of: find.byType(PlayerBar),
                  matching: find.text('离线播放测试曲目'),
                )
                .last,
          );
          await tester.pumpAndSettle();
          expect(find.text('正在播放'), findsOneWidget);
          if (launch == 0 && captureDirectory.isNotEmpty) {
            await _capture(captureKey, captureDirectory, 'player');
          }
          await tester.tap(find.byTooltip('收起播放器'));
          await tester.pumpAndSettle();
          await dependencies.playback.toggle();
          await _until(tester, () => !dependencies.playback.state.playing);
          await dependencies.playback.seek(const Duration(seconds: 1));
          await _until(
            tester,
            () => dependencies.playback.state.position.inMilliseconds >= 800,
          );
          await dependencies.playback.next();
          await _until(
            tester,
            () =>
                dependencies.playback.currentIndex == 1 &&
                dependencies.playback.state.position.inMilliseconds > 100,
          );
          expect(dependencies.playback.state.error, isNull);
          if (launch == 1) {
            if (systemControls) {
              dependencies.playback.setMode(PlaybackMode.repeatAll);
              debugPrint('SYSTEM_READY_PAUSE');
              await _systemUntil(
                tester,
                () => !dependencies.playback.state.playing,
              );
              debugPrint('SYSTEM_READY_PLAY');
              await _systemUntil(
                tester,
                () => dependencies.playback.state.playing,
              );
              debugPrint('SYSTEM_READY_NEXT');
              await _systemUntil(
                tester,
                () => dependencies.playback.currentIndex == 0,
              );
              await _systemUntil(tester, () => !dependencies.playback.loading);
              await dependencies.playback.pause();
              await dependencies.playback.seek(Duration.zero);
              await _systemUntil(
                tester,
                () => dependencies.playback.state.position.inMilliseconds < 800,
              );
              debugPrint('SYSTEM_READY_SEEK');
              await _systemUntil(
                tester,
                () => dependencies.playback.state.position.inSeconds >= 5,
              );
              debugPrint('SYSTEM_READY_STOP');
              await _systemUntil(
                tester,
                () => dependencies.playback.current == null,
              );
              debugPrint('SYSTEM_CONTROLS_PASSED');
            }
            if (find.byTooltip('下载管理').evaluate().isNotEmpty) {
              await tester.tap(find.byTooltip('下载管理'));
            } else {
              await tester.tap(find.text('下载').last);
            }
            await tester.pumpAndSettle();
            await tester.tap(find.text('已下载').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('删除本地文件'));
            await _until(
              tester,
              () => find.text('暂无下载任务，可在歌单中选择曲目下载。').evaluate().isNotEmpty,
            );
            expect(dependencies.playback.current, isNull);
            expect(await media.exists(), isFalse);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await dependencies.dispose();
        }
        debugPrint(
          'Native playback, duration, position, pause, seek, next, offline recreation and file release passed.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await dependencies.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _capture(GlobalKey key, String directory, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/ui-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  final labels = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .join(' | ');
  fail(
    'Native playback did not reach the expected state. Visible labels: $labels',
  );
}

Future<void> _systemUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 1200; attempt++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('System media command did not reach the playback controller.');
  });
}

Uint8List _wave({int seconds = 4}) {
  const rate = 44100;
  final samples = rate * seconds;
  final data = ByteData(44 + samples * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / rate) * 12000).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

class _Keys extends ApiKeyStore {
  @override
  Future<String?> read(String serverKey) async => 'offline-test-key';
}

class _OfflineClient extends PikmeloApiClient {
  _OfflineClient(Uri uri, String key) : super(serverUri: uri, apiKey: key);
  @override
  Future<Map<String, dynamic>> checkHealth() async =>
      throw const SocketException('Offline test');
}
