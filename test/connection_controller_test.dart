import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/app/pikmelo_app.dart';
import 'package:pikmelo_player/downloads/models/download_task.dart';
import 'package:pikmelo_player/downloads/ui/downloads_page.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/settings/connection_controller.dart';
import 'package:pikmelo_player/settings/models/server_connection.dart';
import 'package:pikmelo_player/library/ui/playlist_page.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';
import 'package:pikmelo_player/playback/playback_engine.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/library/models/playlist.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalLibraryStore store;
  late _MemoryKeyStore keys;
  late _ControlledClient client;
  late ConnectionController controller;

  setUp(() async {
    store = await LocalLibraryStore.open(databasePath: ':memory:');
    keys = _MemoryKeyStore();
    client = _ControlledClient();
    controller = ConnectionController(
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: keys,
      openStore: () async => store,
      createClient: (_, _) => client,
    );
  });

  tearDown(() {
    controller.dispose();
    store.close();
  });

  test(
    'single-track progress does not repeatedly scan and notify cache storage',
    () async {
      controller.dispose();
      final engine = _ProgressEngine();
      final player = PlaybackController(
        createEngine: () => engine,
        isAvailable: (_) => true,
      );
      controller = ConnectionController(
        networkReader: () async => {'connected': true, 'cellular': false},
        keyStore: keys,
        openStore: () async => store,
        createClient: (_, _) => client,
        playback: player,
      );
      client.health.complete({'version': 'test'});
      await controller.connectAndSync('https://example.com', 'test-key');
      player.resolveSource = (_) async => '/one.media';
      player.setDefaultMode(PlaybackMode.repeatOne);
      await player.playQueue([
        PlaybackItem(
          serverUri: controller.serverUri,
          path: '/one.media',
          track: Track.fromJson(store.tracks(controller.serverUri).first),
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var notifications = 0;
      controller.addListener(() => notifications++);
      for (var i = 1; i <= 5; i++) {
        await player.seek(Duration(seconds: i));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(notifications, 0);
      controller.setPlaybackCacheLimit(256 * 1024 * 1024);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(notifications, greaterThan(0));
      controller.dispose();
      await controller.downloadShutdown;
      await player.shutdown();
    },
  );

  testWidgets('playlist details show the server description', (tester) async {
    client.playlistFields = {'description': '  服务器上的歌单简介\n第二行内容  '};
    client.health.complete({'version': 'test'});
    await tester.runAsync(
      () => controller.connectAndSync('https://example.com', 'test-key'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistPage(
          controller: controller,
          playlistId: 'playlist-1',
          serverKey: ServerConnection.serverKey(controller.serverUri),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器上的歌单简介\n第二行内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('playlist own cover precedes embedded track cover and remains cached offline', () async {
    final root = await Directory.systemTemp.createTemp(
      'pikmelo-playlist-cover-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => root.path);
    try {
      final embedded = await File(
        'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
      ).readAsBytes();
      final own = await File(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
      ).readAsBytes();
      final file = File('${root.path}/track.media');
      await file.writeAsBytes([
        73,
        68,
        51,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        255,
        251,
        144,
        100,
        ...List.filled(830, 0),
      ]);
      replaceMetadata(
        file,
        Mp3Metadata()
          ..pictures = [Picture(embedded, 'image/png', PictureType.coverFront)],
      );
      client.trackFields = {'size': await file.length()};
      client.playlistFields = {'cover_id': 'playlist-cover'};
      client.covers['playlist-cover'] = own;
      client.health.complete({'version': 'test'});
      await controller.connectAndSync('https://example.com', 'test-key');
      store.saveOfflineMedia(
        serverUri: controller.serverUri,
        expectedGeneration: store.generationFor(controller.serverUri),
        trackId: 'track-1',
        track: store.tracks(controller.serverUri).first,
        file: file,
      );
      expect(await controller.playlistArtwork('playlist-1'), own);
      expect(client.coverCalls, ['playlist-cover']);
      client.covers.clear();
      expect(await controller.playlistArtwork('playlist-1'), own);
      expect(client.coverCalls, ['playlist-cover']);
      expect(await controller.artworkFor('track-1'), embedded);
    } finally {
      controller.dispose();
      await controller.downloadShutdown;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });

  test('playlist description tolerates missing blank and malformed values', () {
    for (final value in [null, '', '  ', 42]) {
      expect(
        Playlist.fromJson({'id': 'p', 'description': value}).description,
        isNull,
      );
    }
    expect(
      Playlist.fromJson({'id': 'p', 'description': '  line one\nline two  '})
          .description,
      'line one\nline two',
    );
  });

  test(
    'playlist unavailable or missing own cover falls back to the track cover',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pikmelo-playlist-fallback-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => root.path);
      try {
        final image = await File(
          'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
        ).readAsBytes();
        client.trackFields = {'cover_id': 'track-cover'};
        client.playlistFields = {'cover_id': 'unavailable-playlist-cover'};
        client.covers['track-cover'] = image;
        client.health.complete({'version': 'test'});
        await controller.connectAndSync('https://example.com', 'test-key');
        expect(await controller.playlistArtwork('playlist-1'), image);
        expect(client.coverCalls, [
          'unavailable-playlist-cover',
          'track-cover',
        ]);
        client.playlistFields = {};
        await controller.refresh();
        expect(await controller.playlistArtwork('playlist-1'), image);
        expect(client.coverCalls, [
          'unavailable-playlist-cover',
          'track-cover',
        ]);
      } finally {
        controller.dispose();
        await controller.downloadShutdown;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'empty playlist uses its own cover and clears a removed cover',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pikmelo-playlist-empty-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => root.path);
      try {
        final image = await File(
          'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
        ).readAsBytes();
        client.playlistFields = {
          'track_ids': <String>[],
          'unavailable_track_ids': <String>[],
          'cover_id': 'empty-cover',
        };
        client.covers['empty-cover'] = image;
        client.health.complete({'version': 'test'});
        await controller.connectAndSync('https://example.com', 'test-key');
        expect(controller.entriesFor('playlist-1'), isEmpty);
        expect(await controller.playlistArtwork('playlist-1'), image);
        expect(client.coverCalls, ['empty-cover']);
        client.playlistFields.remove('cover_id');
        await controller.refresh();
        expect(await controller.playlistArtwork('playlist-1'), isNull);
        expect(client.coverCalls, ['empty-cover']);
      } finally {
        controller.dispose();
        await controller.downloadShutdown;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets('download status preserves playlist title and action alignment', (
    tester,
  ) async {
    client.health.complete({'version': 'test'});
    await tester.runAsync(
      () => controller.connectAndSync('https://example.com', 'test-key'),
    );
    Widget page() => MaterialApp(
      key: UniqueKey(),
      home: PlaylistPage(
        controller: controller,
        playlistId: 'playlist-1',
        serverKey: ServerConnection.serverKey(controller.serverUri),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final title = tester.getTopLeft(find.text('Song').first);
    final download = tester.getCenter(find.byTooltip('下载曲目').first);
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('pikmelo-row-'),
    );
    final file = File('${root!.path}/audio.media');
    await tester.runAsync(() => file.writeAsBytes(List.filled(5, 0)));
    store.saveOfflineMedia(
      serverUri: controller.serverUri,
      expectedGeneration: store.generationFor(controller.serverUri),
      trackId: 'track-1',
      track: store.tracks(controller.serverUri).first,
      file: file,
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Song').first), title);
    expect(tester.getCenter(find.byTooltip('已下载').first), download);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => root.delete(recursive: true));
  });

  test('normal connection startup restores playback only for the saved credentials', () async {
    controller.dispose();
    PlaybackController player() => PlaybackController(
      createEngine: () => throw StateError('Startup must not open audio'),
      isAvailable: (_) => true,
    );
    ConnectionController connection(PlaybackController playback) =>
        ConnectionController(
          networkReader: () async => {'connected': true, 'cellular': false},
          keyStore: keys,
          openStore: () async => store,
          playback: playback,
          createClient: (_, _) =>
              _ControlledClient()..health.complete({'version': 'test'}),
        );
    final first = player();
    controller = connection(first);
    await controller.connectAndSync('https://example.com', 'test-key');
    first.restoreQueue(
      [
        PlaybackItem(
          serverUri: controller.serverUri,
          track: Track.fromJson(store.tracks(controller.serverUri).first),
          path: '',
        ),
      ],
      position: const Duration(seconds: 4),
      duration: const Duration(seconds: 30),
    );
    controller.dispose();
    await controller.downloadShutdown;
    await first.shutdown();
    final second = player();
    controller = connection(second);
    await controller.initialize();
    expect(second.queue.single.track.id, 'track-1');
    expect(second.state.position, const Duration(seconds: 4));
    expect(second.stopped, isTrue);
    await controller.refresh();
    expect(second.queue, hasLength(1));
    await controller.connectAndSync('https://example.com', 'rotated-key');
    expect(second.queue, isEmpty);
    controller.dispose();
    await controller.downloadShutdown;
    await second.shutdown();
  });

  test(
    'downloaded metadata is parsed locally without another server request',
    () async {
      client.health.complete({'version': 'test'});
      await controller.connectAndSync('https://example.com', 'test-key');
      final root = await Directory.systemTemp.createTemp('pikmelo-local-tags-');
      try {
        final file = File('${root.path}/audio.media');
        await file.writeAsBytes([
          73,
          68,
          51,
          4,
          0,
          0,
          0,
          0,
          0,
          0,
          255,
          251,
          144,
          100,
          ...List.filled(830, 0),
        ]);
        replaceMetadata(
          file,
          Mp3Metadata()
            ..album = 'Local Album'
            ..leadPerformer = 'Local Artist'
            ..songName = 'Local Song',
        );
        final data = {
          'id': 'track-1',
          'title': 'Stale title',
          'album': 'Stale album',
          'bits_per_sample': 24,
          'size': await file.length(),
        };
        store.applySyncPages(controller.serverUri, [
          PikmeloSyncPage(
            changedTracks: [data],
            playlists: [],
            deletedTracks: [],
            deletedPlaylists: [],
            cursor: 'updated',
            hasMore: false,
            fullSnapshot: false,
            reset: false,
            revision: 2,
          ),
        ]);
        store.saveOfflineMedia(
          serverUri: controller.serverUri,
          expectedGeneration: store.generationFor(controller.serverUri),
          trackId: 'track-1',
          track: data,
          file: file,
        );
        final local = await controller.metadataFor('track-1');
        expect(local?.album, 'Local Album');
        expect(local?.artist, 'Local Artist');
        expect(local?.title, 'Local Song');
        expect(local?.format, 'mp3');
        expect(local?.bitsPerSample, isNull);
        expect(local?.parsedLocally, isTrue);
        expect(client.syncCalls, 1);
        expect(client.healthCalls, 1);
        expect(
          controller.entriesFor('playlist-1').first.track?.album,
          'Local Album',
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('controller connects once and exposes typed playlists', () async {
    final pending = controller.connectAndSync(
      'https://example.com',
      'test-key',
    );
    expect(controller.busy, isTrue);
    final duplicate = controller.connectAndSync(
      'https://example.com',
      'test-key',
    );
    expect(identical(pending, duplicate), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(client.healthCalls, 1);
    client.health.complete({'version': 'test'});
    await pending;
    expect(controller.connected, isTrue);
    expect(controller.busy, isFalse);
    expect(controller.error, isNull);
    expect(controller.playlists.single.name, 'Favorites');
    expect(
      keys.values[ServerConnection.serverKey(Uri.parse('https://example.com'))],
      'test-key',
    );
    expect(client.closed, isTrue);
  });

  test(
    'disposing during connection closes client and suppresses late work',
    () async {
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.connectAndSync(
        'https://example.com',
        'test-key',
      );
      final beforeDispose = notifications;
      controller.dispose();
      client.health.complete({'version': 'test'});
      await pending;
      expect(client.closed, isTrue);
      expect(client.syncCalls, 0);
      expect(keys.values, isEmpty);
      expect(notifications, beforeDispose);
    },
  );

  test('invalid connection stays in an actionable error state', () async {
    await controller.connectAndSync('http://example.com', 'test-key');
    expect(controller.error, isNotEmpty);
    expect(controller.busy, isFalse);
    expect(client.healthCalls, 0);
  });

  test('authentication failure closes client and clears busy state', () async {
    final pending = controller.connectAndSync(
      'https://example.com',
      'test-key',
    );
    await Future<void>.delayed(Duration.zero);
    client.health.completeError(
      const PikmeloApiException(401, 'UNAUTHORIZED', 'Invalid key'),
    );
    await pending;
    expect(controller.connected, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.error, 'UNAUTHORIZED：Invalid key');
    expect(client.closed, isTrue);
    expect(keys.values, isEmpty);
  });

  test('disposing while database opens prevents synchronization', () async {
    controller.dispose();
    final opening = Completer<LocalLibraryStore>();
    controller = ConnectionController(
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: keys,
      openStore: () => opening.future,
      createClient: (_, _) => client,
    );
    client.health.complete({'version': 'test'});
    final pending = controller.connectAndSync(
      'https://example.com',
      'test-key',
    );
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    opening.complete(store);
    await pending;
    expect(client.syncCalls, 0);
    expect(client.closed, isTrue);
  });

  test(
    'dependencies reuse database and close an opening store on disposal',
    () async {
      final opening = Completer<LocalLibraryStore>();
      var openCalls = 0;
      final dependencies = AppDependencies(
        enableUpdates: false,
        networkReader: () async => {'connected': true, 'cellular': false},
        openStore: () {
          openCalls++;
          return opening.future;
        },
      );
      final first = dependencies.openStore();
      final second = dependencies.openStore();
      final disposing = dependencies.dispose();
      final ownedStore = await LocalLibraryStore.open(databasePath: ':memory:');
      opening.complete(ownedStore);
      await Future.wait([first, second]);
      await disposing;
      expect(openCalls, 1);
      expect(
        () => ownedStore.playlists(Uri.parse('https://example.com')),
        throwsStateError,
      );
      await expectLater(dependencies.openStore(), throwsStateError);
    },
  );

  test(
    'dependencies allow retry after a synchronous database open failure',
    () async {
      var openCalls = 0;
      final dependencies = AppDependencies(
        enableUpdates: false,
        networkReader: () async => {'connected': true, 'cellular': false},
        openStore: () {
          openCalls++;
          if (openCalls == 1) throw StateError('Open failed');
          return LocalLibraryStore.open(databasePath: ':memory:');
        },
      );
      addTearDown(dependencies.dispose);
      await expectLater(dependencies.openStore(), throwsStateError);
      final recovered = await dependencies.openStore();
      expect(recovered.playlists(Uri.parse('https://example.com')), isEmpty);
      expect(openCalls, 2);
    },
  );

  testWidgets('connection form displays the synchronized typed playlist', (
    tester,
  ) async {
    final uiClient = _ControlledClient();
    final dependencies = AppDependencies(
      enableUpdates: false,
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: _MemoryKeyStore(),
      openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
      createClient: (_, _) => uiClient,
    );
    try {
      await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('服务器配置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'invalid-server');
      await tester.enterText(find.byType(TextField).last, 'test-key');
      await Scrollable.ensureVisible(tester.element(find.byType(FilledButton)));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('服务器连接'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'test-key');
      await Scrollable.ensureVisible(tester.element(find.byType(FilledButton)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      uiClient.health.complete({'version': 'test'});
      await tester.pumpAndSettle();
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('已连接 · test · 同步 1 页'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'no-matching-music');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的歌单'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Song');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Song'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '已下载'));
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的歌单'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(find.text('Favorites')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();
      expect(find.text('不可用曲目'), findsOneWidget);
      expect(find.text('暂不可用'), findsOneWidget);
      expect(find.text('Song'), findsNWidgets(2));
      expect(find.text('可下载'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await dependencies.dispose();
    }
  });

  testWidgets('late saved credentials respect a changed server address', (
    tester,
  ) async {
    final delayedKeys = _DelayedKeyStore();
    final dependencies = AppDependencies(
      enableUpdates: false,
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: delayedKeys,
      openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
    );
    try {
      await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
      await tester.pump();
      await tester.tap(find.text('设置').last);
      await tester.pump();
      await tester.tap(find.text('服务器配置'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'https://other.com');
      delayedKeys.reading.complete('old-server-key');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.controller!.text, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await dependencies.dispose();
    }
  });

  test('restart restores cached library before an offline refresh', () async {
    client.health.complete({'version': 'test'});
    await controller.connectAndSync('https://example.com', 'test-key');
    final restored = ConnectionController(
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: keys,
      openStore: () async => store,
      createClient: (_, _) => throw const SocketException('Offline'),
    );
    addTearDown(restored.dispose);
    final settings = await restored.initialize();
    expect(settings?.serverUri, Uri.parse('https://example.com'));
    expect(restored.playlists.single.name, 'Favorites');
    await restored.refresh();
    expect(restored.playlists.single.name, 'Favorites');
    expect(restored.connected, isFalse);
    expect(restored.status, '离线 · 显示本地曲库');
  });

  test('switching keys cancels stale pages before database commit', () async {
    controller.dispose();
    final old = _ControlledClient()..syncPage = Completer<PikmeloSyncPage>();
    final next = _ControlledClient(playlistName: 'New scope');
    addTearDown(old.close);
    addTearDown(next.close);
    old.health.complete({'version': 'test'});
    next.health.complete({'version': 'test'});
    controller = ConnectionController(
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: keys,
      openStore: () async => store,
      createClient: (_, key) => key == 'key-a' ? old : next,
    );
    final stale = controller.connectAndSync('https://example.com', 'key-a');
    await Future<void>.delayed(Duration.zero);
    expect(old.syncCalls, 1);
    await controller.connectAndSync('https://example.com', 'key-b');
    old.syncPage!.complete(
      const PikmeloSyncPage(
        changedTracks: [],
        playlists: [
          {'id': 'old', 'name': 'Old scope'},
        ],
        deletedTracks: [],
        deletedPlaylists: [],
        cursor: 'stale',
        hasMore: false,
        fullSnapshot: true,
        reset: true,
        revision: 0,
      ),
    );
    await stale;
    expect(old.closed, isTrue);
    expect(controller.playlists.single.name, 'New scope');
    expect(store.cursorFor(Uri.parse('https://example.com')), 'cursor');
    expect(
      keys.values[ServerConnection.serverKey(Uri.parse('https://example.com'))],
      'key-b',
    );
  });

  test(
    'authorization failure removes cached visibility and revokes offline media',
    () async {
      controller.dispose();
      final denied = _ControlledClient();
      addTearDown(denied.close);
      var calls = 0;
      controller = ConnectionController(
        networkReader: () async => {'connected': true, 'cellular': false},
        keyStore: keys,
        openStore: () async => store,
        createClient: (_, _) => calls++ == 0 ? client : denied,
      );
      client.health.complete({'version': 'test'});
      await controller.connectAndSync('https://example.com', 'test-key');
      final directory = await Directory.systemTemp.createTemp(
        'pikmelo-revoke-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}song.media');
      await file.writeAsBytes([1, 2, 3, 4, 5]);
      final uri = Uri.parse('https://example.com');
      store.saveOfflineMedia(
        serverUri: uri,
        expectedGeneration: store.generationFor(uri),
        trackId: 'track-1',
        track: {'id': 'track-1', 'size': 5},
        file: file,
      );
      expect(
        controller.entriesFor('playlist-1').where((entry) => entry.downloaded),
        hasLength(2),
      );
      await file.delete();
      expect(
        controller.entriesFor('playlist-1').any((entry) => entry.downloaded),
        isFalse,
      );
      await file.writeAsBytes([1, 2, 3, 4, 5]);
      final pending = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      denied.health.completeError(
        const PikmeloApiException(403, 'FORBIDDEN', 'Denied'),
      );
      await pending;
      expect(controller.playlists, isEmpty);
      expect(store.playlists(uri), isEmpty);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
      expect(
        store.offlineTracks(serverUri: uri, authorizedOnly: false),
        hasLength(1),
      );
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'switching servers retains separate snapshots and persists selection',
    () async {
      controller.dispose();
      controller = ConnectionController(
        networkReader: () async => {'connected': true, 'cellular': false},
        keyStore: keys,
        openStore: () async => store,
        createClient: (connection, _) =>
            _ControlledClient(playlistName: connection.uri.host)
              ..health.complete({'version': 'test'}),
      );
      final first = Uri.parse('https://first.com');
      final second = Uri.parse('https://second.com');
      await controller.connectAndSync(first.toString(), 'test-key');
      await controller.connectAndSync(second.toString(), 'test-key');
      expect(store.playlists(first).single['name'], 'first.com');
      expect(controller.playlists.single.name, 'second.com');
      expect(store.selectedServer(), second);
    },
  );

  test(
    'legacy credential keys restore cached data and migrate after connection',
    () async {
      final uri = Uri.parse('https://example.com');
      keys.values['https://example.com/'] = 'legacy-key';
      store.saveSelectedServer(uri);
      store.applySyncPages(uri, [
        const PikmeloSyncPage(
          changedTracks: [],
          playlists: [
            {'id': 'legacy', 'name': 'Legacy'},
          ],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'legacy-cursor',
          hasMore: false,
          fullSnapshot: true,
          reset: false,
          revision: 1,
        ),
      ]);
      await controller.initialize();
      expect(controller.playlists.single.name, 'Legacy');
      expect(store.cursorFor(uri), 'legacy-cursor');
      client.health.complete({'version': 'test'});
      await controller.refresh();
      expect(keys.values[ServerConnection.serverKey(uri)], 'legacy-key');
      expect(keys.values.containsKey('https://example.com/'), isFalse);
    },
  );

  testWidgets('returning to the foreground refreshes the selected connection', (
    tester,
  ) async {
    final clients = <_ControlledClient>[];
    final dependencies = AppDependencies(
      enableUpdates: false,
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: _MemoryKeyStore(),
      openStore: () => LocalLibraryStore.open(databasePath: ':memory:'),
      createClient: (_, _) {
        final current = _ControlledClient()
          ..health.complete({'version': 'test'});
        clients.add(current);
        return current;
      },
    );
    try {
      await tester.pumpWidget(PikmeloPlayerApp(dependencies: dependencies));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('服务器配置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'test-key');
      await Scrollable.ensureVisible(tester.element(find.byType(FilledButton)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(clients.length, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(clients.length, 2);
      expect(clients.every((client) => client.closed), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await dependencies.dispose();
    }
  });
  testWidgets('download page restores paused tasks and supports cancellation', (
    tester,
  ) async {
    controller.dispose();
    controller = ConnectionController(
      keyStore: keys,
      openStore: () async => store,
      createClient: (_, _) => client,
      networkReader: () async => {'connected': true, 'cellular': false},
    );
    final uri = Uri.parse('https://example.com');
    keys.values[ServerConnection.serverKey(uri)] = 'test-key';
    store.saveSelectedServer(uri);
    store.applySyncPages(uri, [
      const PikmeloSyncPage(
        changedTracks: [
          {'id': 'track-1', 'title': 'Download song', 'size': 10},
        ],
        playlists: [],
        deletedTracks: [],
        deletedPlaylists: [],
        cursor: 'download',
        hasMore: false,
        fullSnapshot: true,
        reset: false,
        revision: 1,
      ),
    ]);
    store.saveDownloadQueue(uri, 'track-1', 'paused', 0, null);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: DownloadsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download song'), findsOneWidget);
    expect(find.textContaining('已暂停'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('暂无下载任务，可在歌单中选择曲目下载。'), findsOneWidget);
    expect(store.downloadQueue(uri), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await controller.downloadShutdown;
  });

  test('synchronization waits for active download cleanup and preserves pause state', () async {
    controller.dispose();
    final directory = Completer<Directory>();
    controller = ConnectionController(
      networkReader: () async => {'connected': true, 'cellular': false},
      keyStore: keys,
      openStore: () async => store,
      cacheDirectory: () => directory.future,
      createClient: (_, _) =>
          _ControlledClient()..health.complete({'version': 'test'}),
    );
    final uri = Uri.parse('https://example.com');
    await controller.connectAndSync(uri.toString(), 'test-key');
    controller.enqueueDownload('track-1');
    await Future<void>.delayed(Duration.zero);
    final generation = store.generationFor(uri);
    expect(
      controller.downloads!.tasks.single.status,
      DownloadStatus.downloading,
    );
    final sync = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(store.generationFor(uri), generation);
    directory.complete(Directory.systemTemp);
    await sync;
    expect(store.generationFor(uri), greaterThan(generation));
    expect(controller.downloads!.tasks.single.status, DownloadStatus.paused);
  });
}

class _DelayedKeyStore extends ApiKeyStore {
  final reading = Completer<String?>();

  @override
  Future<String?> read(String serverKey) => reading.future;
}

class _MemoryKeyStore extends ApiKeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String serverKey) async => values[serverKey];

  @override
  Future<void> save(String serverKey, String apiKey) async {
    values[serverKey] = apiKey;
  }

  @override
  Future<void> delete(String serverKey) async => values.remove(serverKey);
}

class _ControlledClient extends PikmeloApiClient {
  _ControlledClient({this.playlistName = 'Favorites'})
    : super(serverUri: ServerConnection.defaultUri, apiKey: 'test-key');

  final String playlistName;
  Map<String, dynamic> playlistFields = {};
  Map<String, dynamic> trackFields = {};
  final covers = <String, Uint8List>{};
  final coverCalls = <String>[];

  @override
  Future<Uint8List?> fetchCover(String id) async {
    coverCalls.add(id);
    return covers[id];
  }

  Completer<PikmeloSyncPage>? syncPage;

  final health = Completer<Map<String, dynamic>>();
  var healthCalls = 0;
  var syncCalls = 0;
  var closed = false;

  @override
  Future<Map<String, dynamic>> checkHealth() {
    healthCalls++;
    return health.future;
  }

  @override
  Future<PikmeloSyncPage> fetchSyncPage({
    String? cursor,
    int limit = 100,
  }) async {
    syncCalls++;
    if (syncPage != null) return syncPage!.future;
    return PikmeloSyncPage(
      changedTracks: [
        {'id': 'track-1', 'title': 'Song', 'size': 5, ...trackFields},
      ],
      playlists: [
        {
          'id': 'playlist-1',
          'name': playlistName,
          'track_ids': ['track-1', 'missing', 'track-1'],
          'unavailable_track_ids': ['missing'],
          ...playlistFields,
        },
      ],
      deletedTracks: [],
      deletedPlaylists: [],
      cursor: 'cursor',
      hasMore: false,
      fullSnapshot: true,
      reset: true,
      revision: 1,
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _ProgressEngine implements PlaybackEngine {
  final _events = StreamController<PlaybackState>.broadcast(sync: true);
  PlaybackState _state = const PlaybackState(duration: Duration(seconds: 60));
  void _emit(PlaybackState state) {
    _state = state;
    _events.add(state);
  }

  @override
  Stream<PlaybackState> get states => _events.stream;
  @override
  Future<void> open(String path) async => _emit(_state);
  @override
  Future<void> play() async => _emit(_state.copyWith(playing: true));
  @override
  Future<void> pause() async => _emit(_state.copyWith(playing: false));
  @override
  Future<void> seek(Duration position) async =>
      _emit(_state.copyWith(position: position));
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() => _events.close();
}
