import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/artwork/embedded_resources.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/lyrics/lrc_parser.dart';
import 'package:pikmelo_player/lyrics/lyrics_controller.dart';
import 'package:pikmelo_player/lyrics/lyrics_repository.dart';
import 'package:pikmelo_player/lyrics/models/lyric_document.dart';
import 'package:pikmelo_player/lyrics/ui/three_line_lyrics.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';
import 'package:pikmelo_player/playback/playback_engine.dart';
import 'package:pikmelo_player/playback/ui/now_playing_page.dart';
import 'package:pikmelo_player/playback/ui/playback_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = LyricsSource.embedded;
  test('LRC normalizes BOM CRLF metadata fractions and offset', () {
    final doc = parseLyrics(
      '\ufeff[ar:artist]\r\n[offset:100]\r\n[00:01.2]one\r[00:02:34]two\n[00:03.456]three',
      source,
    )!;
    expect(doc.cues.map((c) => c.start.inMilliseconds), [1100, 2240, 3356]);
    expect(doc.cues.map((c) => c.text), ['one', 'two', 'three']);
    expect(doc.indexAt(const Duration(milliseconds: 1099)), -1);
    expect(doc.indexAt(const Duration(milliseconds: 1100)), 0);
    expect(doc.indexAt(const Duration(days: 1)), 2);
  });
  test(
    'LRC expands timestamps sorts and groups translations and duplicates',
    () {
      final doc = parseLyrics(
        '[00:03][00:01]main\n[00:01]translation\n[00:01]main\n[00:02]',
        source,
      )!;
      expect(doc.cues.map((c) => c.text), ['main', '', 'main']);
      expect(doc.cues.first.parallelText, ['translation']);
      expect(() => doc.cues.clear(), throwsUnsupportedError);
    },
  );
  test('plain text remains unsynchronized and empty metadata is absent', () {
    expect(
      parseLyrics('[ti:title]\nfirst\nsecond', source)!.synchronized,
      false,
    );
    expect(parseLyrics('[ti:title]\n[00:01]', source), isNull);
    expect(parseLyrics('  ', source), isNull);
    expect(
      parseLyrics('[00:61]bad time', source)!.plainText,
      '[00:61]bad time',
    );
    expect(
      parseLyrics(
        '[offset:2000]\n[00:01]early',
        source,
      )!.indexAt(Duration.zero),
      0,
    );
  });
  test('untrusted lyrics size and cue count are bounded', () {
    expect(
      () => parseLyrics('a' * (2 * 1024 * 1024 + 1), source),
      throwsFormatException,
    );
    expect(() => parseLyrics('line\n' * 20001, source), throwsFormatException);
  });

  group('repository', () {
    late LocalLibraryStore store;
    late Directory directory;
    late File file;
    late Track track;
    setUp(() async {
      store = await LocalLibraryStore.open(databasePath: ':memory:');
      directory = await Directory.systemTemp.createTemp('pikmelo-lyrics-');
      file = await File('${directory.path}/track.media').writeAsString('audio');
      track = Track.fromJson({
        'id': 'one',
        'title': 'one',
        'lyrics': '[00:01]server',
      });
    });
    tearDown(() async {
      store.close();
      await directory.delete(recursive: true);
    });
    Future<LyricDocument?> load(
      LyricsRepository repository, {
      String? path,
      String scope = 'scope',
      String retry = '',
      bool Function()? allowed,
      Future<String?> Function()? fetch,
    }) => repository.load(
      scope: scope,
      track: track,
      path: path,
      store: store,
      retryToken: retry,
      allowed: allowed ?? () => true,
      fetchServer: fetch ?? () async => null,
    );
    test(
      'embedded plain text wins over synchronized server lyrics and persists',
      () async {
        var reads = 0;
        final repository = LyricsRepository(
          readEmbedded: (_, _) async {
            reads++;
            return const EmbeddedResources(lyrics: 'local plain');
          },
        );
        final doc = await load(repository, path: file.path);
        expect(doc!.source, LyricsSource.embedded);
        expect(doc.synchronized, false);
        final reopened = LyricsRepository(
          readEmbedded: (_, _) async => throw StateError('should use cache'),
        );
        expect(
          (await load(reopened, path: file.path))!.plainText,
          'local plain',
        );
        expect(reads, 1);
      },
    );
    test(
      'absent embedded lyrics use server without fetching when synced',
      () async {
        final repository = LyricsRepository(
          readEmbedded: (_, _) async => const EmbeddedResources(),
        );
        expect(
          (await load(
            repository,
            path: file.path,
            fetch: () async => throw StateError('unexpected fetch'),
          ))!.source,
          LyricsSource.server,
        );
        expect(store.localLyrics(file.path), {'text': null});
      },
    );
    test('new downloaded file supersedes earlier server result and fingerprint invalidates', () async {
      var reads = 0;
      final repository = LyricsRepository(
        readEmbedded: (_, _) async =>
            EmbeddedResources(lyrics: '[00:01]local ${++reads}'),
      );
      expect((await load(repository))!.source, LyricsSource.server);
      expect((await load(repository, path: file.path))!.plainText, 'local 1');
      await file.writeAsString('different audio size');
      expect((await load(repository, path: file.path))!.plainText, 'local 2');
    });
    test('authorization revocation discards delayed embedded result and persistence', () async {
      var allowed = true;
      final pending = Completer<EmbeddedResources>();
      final repository = LyricsRepository(
        readEmbedded: (_, _) => pending.future,
      );
      final result = load(repository, path: file.path, allowed: () => allowed);
      allowed = false;
      pending.complete(const EmbeddedResources(lyrics: 'private'));
      expect(await result, isNull);
      expect(store.localLyrics(file.path), isNull);
    });
    test(
      'server requests coalesce and cache isolates credential scopes',
      () async {
        track = Track.fromJson({'id': 'one', 'title': 'one'});
        var calls = 0;
        Future<String?> fetch() async {
          calls++;
          return '[00:01]$calls';
        }

        final repository = LyricsRepository();
        await Future.wait([
          load(repository, fetch: fetch),
          load(repository, fetch: fetch),
        ]);
        expect(calls, 1);
        expect(
          (await load(
            LyricsRepository(),
            fetch: () async => throw StateError('offline'),
          ))!.plainText,
          '1',
        );
        expect(
          (await load(repository, scope: 'new-key', fetch: fetch))!.plainText,
          '2',
        );
      },
    );
    test(
      'failed reads are retryable and successful absence is distinct',
      () async {
        track = Track.fromJson({'id': 'one', 'title': 'one'});
        var fail = true;
        final repository = LyricsRepository(
          readEmbedded: (_, _) async => fail
              ? const EmbeddedResources(readSucceeded: false)
              : const EmbeddedResources(lyrics: 'recovered'),
        );
        await expectLater(
          load(repository, path: file.path),
          throwsA(isA<LyricsUnavailable>()),
        );
        expect(store.localLyrics(file.path), isNull);
        fail = false;
        expect(
          (await load(repository, path: file.path, retry: 'retry'))!.plainText,
          'recovered',
        );
        expect(await load(LyricsRepository()), isNull);
        await expectLater(
          load(
            LyricsRepository(),
            fetch: () async => throw const SocketException('offline'),
          ),
          throwsA(isA<LyricsUnavailable>()),
        );
      },
    );
  });

  group('playback lyrics', () {
    late PlaybackController player;
    late List<_Engine> engines;
    final items = List.generate(
      2,
      (i) => PlaybackItem(
        serverUri: Uri.parse('https://example.com'),
        track: Track.fromJson({'id': '$i', 'title': 'Song $i'}),
        path: '/$i.media',
      ),
    );
    setUp(() {
      engines = [];
      player = PlaybackController(
        createEngine: () {
          final engine = _Engine();
          engines.add(engine);
          return engine;
        },
        isAvailable: (_) => true,
      );
    });
    tearDown(() async {
      player.dispose();
      await player.shutdown();
    });
    test(
      'late result from prior track cannot replace current lyrics',
      () async {
        final pending = Completer<LyricDocument?>();
        player.loadLyrics = (item) => item.track.id == '0'
            ? pending.future
            : Future.value(parseLyrics('[00:00]new', source));
        final lyrics = LyricsController(player);
        await player.playQueue(items);
        await player.jump(1);
        await Future<void>.delayed(Duration.zero);
        pending.complete(parseLyrics('[00:00]old', source));
        await Future<void>.delayed(Duration.zero);
        expect(lyrics.document!.plainText, 'new');
        lyrics.dispose();
      },
    );
    test(
      'position ticks reuse document and seek immediately selects the target',
      () async {
        var loads = 0;
        player.loadLyrics = (_) async {
          loads++;
          return parseLyrics('[00:01]one\n[00:02]two\n[00:03]three', source);
        };
        final lyrics = LyricsController(player);
        await player.playQueue(items);
        await Future<void>.delayed(Duration.zero);
        var notifications = 0;
        lyrics.addListener(() => notifications++);
        engines.last.emit(1100);
        engines.last.emit(1200);
        engines.last.emit(1300);
        expect(lyrics.index, 0);
        expect(notifications, 1);
        await player.seek(const Duration(milliseconds: 2100));
        expect(lyrics.index, 1);
        expect(lyrics.snap, true);
        engines.last.emit(3100);
        expect(lyrics.index, 2);
        player.invalidateLyrics();
        await Future<void>.delayed(Duration.zero);
        expect(loads, 2);
        lyrics.dispose();
      },
    );
    test('paused and buffering playback freeze next-cue timers', () async {
      player.loadLyrics = (_) async =>
          parseLyrics('[00:00]one\n[00:00.040]two', source);
      final lyrics = LyricsController(player);
      await player.playQueue(items);
      await Future<void>.delayed(Duration.zero);
      engines.last.emit(0, playing: false);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(lyrics.index, 0);
      engines.last.emit(0, buffering: true);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(lyrics.index, 0);
      engines.last.emit(0);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(lyrics.index, 1);
      lyrics.dispose();
    });
    testWidgets(
      'three lyric rows transition without moving the footer at supported sizes',
      (tester) async {
        player.loadLyrics = (_) async => parseLyrics(
          '[00:01]first\n[00:02]second\n[00:03]third\n[00:04]fourth',
          source,
        );
        await tester.runAsync(() => player.playQueue(items));
        for (final size in [
          const Size(320, 640),
          const Size(390, 844),
          const Size(640, 360),
          const Size(1280, 800),
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          for (final scale in [1.0, 1.8]) {
            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: NowPlayingPage(controller: player),
                ),
              ),
            );
            await tester.pump();
            engines.last.emit(2100, playing: false);
            await tester.pump();
            final before = tester.getRect(find.byType(PlaybackProgress));
            expect(find.text('first'), findsOneWidget);
            expect(find.text('second'), findsOneWidget);
            expect(find.text('third'), findsOneWidget);
            engines.last.emit(3100, playing: false);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 130));
            expect(tester.getRect(find.byType(PlaybackProgress)), before);
            expect(tester.takeException(), isNull);
            await tester.pump(const Duration(milliseconds: 300));
          }
        }
        await tester.pumpWidget(const SizedBox());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      },
    );
    testWidgets(
      'lyric transition frames reuse text and leave siblings unpainted',
      (tester) async {
        player.loadLyrics = (_) async =>
            parseLyrics('[00:00]first\n[00:01]second\n[00:02]third', source);
        await tester.runAsync(() => player.playQueue(items));
        final painter = _PaintCounter();
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: [
                CustomPaint(size: const Size(100, 100), painter: painter),
                ThreeLineLyrics(player: player),
              ],
            ),
          ),
        );
        await tester.pump();
        engines.last.emit(1100, playing: false);
        await tester.pump();
        var builds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is Text) builds++;
        };
        painter.paints = 0;
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        debugOnRebuildDirtyWidget = previous;
        expect(builds, 0);
        expect(painter.paints, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'loading empty plain error retry and reduced motion are visible',
      (tester) async {
        final pending = Completer<LyricDocument?>();
        player.loadLyrics = (_) => pending.future;
        await tester.runAsync(() => player.playQueue(items));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(body: ThreeLineLyrics(player: player)),
            ),
          ),
        );
        expect(find.text('正在读取歌词…'), findsOneWidget);
        pending.complete(null);
        await tester.pump();
        expect(find.text('暂无歌词'), findsOneWidget);
        player.loadLyrics = (_) async =>
            parseLyrics('plain line\nsecond line', source);
        player.invalidateLyrics();
        await tester.pump();
        await tester.pump();
        expect(find.text('未同步歌词'), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        player.loadLyrics = (_) async => throw const LyricsUnavailable();
        player.invalidateLyrics();
        await tester.pump();
        await tester.pump();
        expect(find.text('歌词暂不可用，轻点重试'), findsOneWidget);
        player.loadLyrics = (_) async =>
            parseLyrics('[00:00]current\n[00:01]next', source);
        await tester.tap(find.text('歌词暂不可用，轻点重试'));
        await tester.pump();
        await tester.pump();
        expect(find.text('current'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}

class _Engine implements PlaybackEngine {
  final _states = StreamController<PlaybackState>.broadcast(sync: true);
  void emit(int milliseconds, {bool playing = true, bool buffering = false}) =>
      _states.add(
        PlaybackState(
          playing: playing,
          buffering: buffering,
          position: Duration(milliseconds: milliseconds),
          duration: const Duration(seconds: 30),
        ),
      );
  @override
  Stream<PlaybackState> get states => _states.stream;
  @override
  Future<void> open(String path) async {
    emit(0, playing: false);
  }

  @override
  Future<void> play() async {
    emit(0);
  }

  @override
  Future<void> pause() async {
    emit(0, playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    emit(position.inMilliseconds);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() => _states.close();
}

class _PaintCounter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}
