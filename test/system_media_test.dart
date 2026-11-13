import 'package:pikmelo_player/lyrics/ui/three_line_lyrics.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' as system;
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pikmelo_player/infrastructure/platform/playback_audio_session.dart';
import 'package:pikmelo_player/infrastructure/platform/system_audio_handler.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';
import 'package:pikmelo_player/playback/playback_engine.dart';
import 'package:pikmelo_player/playback/ui/player_bar.dart';
import 'package:pikmelo_player/playback/ui/queue_page.dart';
import 'package:pikmelo_player/playback/ui/now_playing_page.dart';
import 'package:pikmelo_player/playback/ui/playback_controls.dart';
import 'package:pikmelo_player/playback/ui/scrolling_track_text.dart';

void main() {
  late PlaybackController controller;
  late PlaybackAudioSession focus;
  late SystemAudioHandler handler;
  late StreamController<AudioInterruptionEvent> interruptions;
  late StreamController<void> noisy;
  late List<_Engine> engines;
  late List<bool> activations;
  var allowFocus = true;
  final item = PlaybackItem(
    serverUri: Uri.parse('https://example.com'),
    track: Track.fromJson({'id': 'one', 'title': '测试曲目', 'artist': '测试歌手'}),
    path: '/one.media',
  );

  setUp(() {
    engines = [];
    activations = [];
    allowFocus = true;
    interruptions = StreamController.broadcast(sync: true);
    noisy = StreamController.broadcast(sync: true);
    controller = PlaybackController(
      createEngine: () {
        final engine = _Engine();
        engines.add(engine);
        return engine;
      },
      isAvailable: (_) => true,
    );
    focus = PlaybackAudioSession(
      controller: controller,
      setActive: (active) async {
        activations.add(active);
        return !active || allowFocus;
      },
      interruptions: interruptions.stream,
      becomingNoisy: noisy.stream,
    );
    handler = SystemAudioHandler()..attach(controller);
  });
  tearDown(() async {
    handler.attach(null);
    await focus.dispose();
    controller.dispose();
    await controller.shutdown();
    await interruptions.close();
    await noisy.close();
  });

  for (final surface in ['page', 'bar', 'queue']) {
    testWidgets('$surface progress refreshes reuse the artwork request', (
      tester,
    ) async {
      handler.attach(null);
      var requests = 0;
      controller.loadArtwork = (_) {
        requests++;
        return Future.value(null);
      };
      final second = PlaybackItem(
        serverUri: item.serverUri,
        path: '/two.media',
        track: Track.fromJson({'id': 'two', 'title': 'Second'}),
      );
      await tester.runAsync(() => controller.playQueue([item, second]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: switch (surface) {
              'bar' => PlayerBar(controller: controller),
              'queue' => QueueContents(controller: controller),
              _ => NowPlayingPage(controller: controller),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, surface == 'queue' ? 2 : 1);
      for (var index = 1; index <= 5; index++) {
        await tester.runAsync(() => controller.seek(Duration(seconds: index)));
        await tester.pumpAndSettle();
      }
      expect(requests, surface == 'queue' ? 2 : 1);
      await tester.runAsync(() => controller.jump(1));
      await tester.pumpAndSettle();
      expect(requests, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'transport trio is centered with symmetric action slots at every width',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() => controller.playQueue([item]));
      for (final size in [
        const Size(320, 640),
        const Size(360, 780),
        const Size(390, 844),
        const Size(640, 360),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(home: NowPlayingPage(controller: controller)),
        );
        await tester.pumpAndSettle();
        final play = tester.getCenter(find.byTooltip('暂停'));
        final previous = tester.getCenter(find.byTooltip('上一首'));
        final next = tester.getCenter(find.byTooltip('下一首'));
        expect(play.dx, closeTo(size.width / 2, 0.1));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('player-action-placeholder')))
              .width,
          tester.getSize(find.byTooltip('音量')).width,
        );
        expect(play.dx - previous.dx, closeTo(next.dx - play.dx, 0.1));
        expect(previous.dy, play.dy);
        expect(next.dy, play.dy);
        expect(
          tester.getCenter(find.byTooltip('顺序播放')).dx,
          lessThan(previous.dx),
        );
        expect(
          tester.getCenter(find.byTooltip('播放队列')).dx,
          greaterThan(next.dx),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'player controls are bottom anchored with one queue entry and bitrate',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final track = PlaybackItem(
        serverUri: item.serverUri,
        path: item.path,
        track: Track.fromJson({
          'id': 'one',
          'title': '曲目',
          'artist': '歌手',
          'album': '专辑',
          'bitrate_kbps': 320,
        }),
      );
      await tester.runAsync(() => controller.playQueue([track]));
      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放队列'), findsNothing);
      expect(find.byTooltip('播放队列'), findsOneWidget);
      expect(find.text('320 kbps'), findsOneWidget);
      expect(find.byTooltip('音量'), findsOneWidget);
      final controls = tester.getRect(find.byType(TransportControls));
      expect(844 - controls.bottom, closeTo(32, 0.1));
      expect(
        tester.getTopLeft(find.byType(PlaybackProgress)).dy -
            tester.getBottomRight(find.byType(ThreeLineLyrics)).dy,
        24,
      );
      expect(
        tester.getTopLeft(find.text('320 kbps')).dy,
        lessThan(controls.top),
      );
      expect(
        tester.getBottomRight(find.byType(PlaybackProgress)).dy,
        lessThan(tester.getTopLeft(find.text('320 kbps')).dy),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'long metadata scrolls without restarting on progress and resets on a track change',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long = List.filled(10, '很长的曲目信息 Long metadata ').join();
      PlaybackItem track(String id) => PlaybackItem(
        serverUri: item.serverUri,
        path: '/$id.media',
        track: Track.fromJson({
          'id': id,
          'title': '$long\n末行',
          'artist': long,
          'album': long,
        }),
      );
      await tester.runAsync(
        () => controller.playQueue([track('one'), track('two')]),
      );
      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(controller: controller)),
      );
      await tester.pump();
      final lines = find.byType(ScrollingTrackText);
      expect(lines, findsNWidgets(3));
      for (final line in lines.evaluate()) {
        for (final text
            in find
                .descendant(
                  of: find.byWidget(line.widget),
                  matching: find.byType(Text),
                )
                .evaluate()) {
          expect((text.widget as Text).maxLines, 1);
          expect((text.widget as Text).softWrap, false);
          expect((text.widget as Text).data, isNot(contains('\n')));
        }
      }
      double offset() =>
          tester
              .getTopLeft(
                find
                    .descendant(of: lines.first, matching: find.byType(Text))
                    .first,
              )
              .dx -
          tester.getTopLeft(lines.first).dx;
      expect(offset(), 0);
      await tester.pump(const Duration(seconds: 2));
      final moved = offset();
      expect(moved, lessThan(0));
      final controls = tester.getRect(find.byType(TransportControls));
      await tester.runAsync(() => controller.seek(const Duration(seconds: 1)));
      await tester.pump();
      expect(offset(), closeTo(moved, 0.01));
      await tester.pump(const Duration(milliseconds: 200));
      expect(offset(), lessThan(moved));
      await tester.runAsync(() => controller.jump(1));
      await tester.pump();
      await tester.pump();
      expect(offset(), 0);
      expect(tester.getRect(find.byType(TransportControls)), controls);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'volume opens above its button and vertical dragging changes app volume',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Keep UI-only command futures on the widget test clock.
      final controller = PlaybackController(
        createEngine: () => throw StateError('Volume UI must not open audio'),
        isAvailable: (_) => true,
      );
      controller.restoreQueue([item], volume: 40);
      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final before = tester.getRect(find.byType(TransportControls));
      final anchor = tester.getRect(find.byTooltip('音量'));
      expect(
        anchor.left,
        lessThan(tester.getRect(find.byTooltip('顺序播放')).left),
      );
      await tester.tap(find.byTooltip('音量'));
      await tester.pumpAndSettle();
      final rotated = find.byType(RotatedBox);
      final slider = find.descendant(
        of: rotated,
        matching: find.byType(Slider),
      );
      final bounds = tester.getRect(slider);
      expect(bounds.height, greaterThan(bounds.width));
      expect(bounds.bottom, lessThan(anchor.top));
      expect(find.text('40%'), findsOneWidget);
      await tester.dragFrom(bounds.center, const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(controller.volume, greaterThan(40));
      expect(tester.getRect(find.byType(TransportControls)), before);
      await tester.tapAt(const Offset(350, 200));
      await tester.pumpAndSettle();
      expect(find.byType(RotatedBox), findsNothing);
      await tester.tap(find.byTooltip('播放选项'));
      await tester.pumpAndSettle();
      expect(find.text('音量'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = controller.shutdown();
      await tester.pump();
      await closing;
      controller.dispose();
    },
  );

  testWidgets(
    'long metadata and unknown bitrate fit small and large accessible layouts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long = List.filled(20, 'Long 曲目信息 ').join();
      await tester.runAsync(
        () => controller.playQueue([
          PlaybackItem(
            serverUri: item.serverUri,
            path: item.path,
            track: Track.fromJson({'id': 'long', 'title': long}),
          ),
        ]),
      );
      for (final size in [
        const Size(320, 640),
        const Size(640, 360),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.8),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: NowPlayingPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ScrollingTrackText), findsNWidgets(3));
        expect(find.text('码率未知'), findsOneWidget);
        expect(
          tester.getBottomRight(find.byType(TransportControls)).dy,
          lessThanOrEqualTo(size.height),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('音量'));
        await tester.pumpAndSettle();
        expect(find.byType(RotatedBox), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(Offset(size.width - 16, 72));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'loading cancellation keeps playback controls at fixed coordinates',
    (tester) async {
      final source = Completer<String>();
      controller.resolveSource = (_) => source.future;
      late Future<void> opening;
      await tester.runAsync(() async {
        opening = controller.playQueue([item]);
        await _tick();
      });
      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(controller: controller)),
      );
      final before = tester.getTopLeft(find.byType(PlaybackProgress));
      final controlsBefore = tester.getTopLeft(find.byType(TransportControls));
      source.complete(item.path);
      await tester.runAsync(() => opening);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(PlaybackProgress)), before);
      expect(tester.getTopLeft(find.byType(TransportControls)), controlsBefore);
      expect(find.text('取消播放准备').hitTestable(), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'notification artwork ignores delayed results after a track change',
    () async {
      handler.attach(null);
      handler = SystemAudioHandler(
        saveArtwork: (bytes) async => Uri.file('/cover-${bytes.first}.png'),
      )..attach(controller);
      final first = Completer<Uint8List?>();
      final second = Completer<Uint8List?>();
      final other = PlaybackItem(
        serverUri: item.serverUri,
        track: Track.fromJson({'id': 'two', 'title': 'Second'}),
        path: '/two.media',
      );
      controller.loadArtwork = (current) =>
          current.track.id == 'one' ? first.future : second.future;
      await controller.playQueue([item, other]);
      await controller.jump(1);
      second.complete(Uint8List.fromList([2]));
      await _tick();
      expect(handler.mediaItem.value?.artUri, Uri.file('/cover-2.png'));
      first.complete(Uint8List.fromList([1]));
      await _tick();
      expect(handler.mediaItem.value?.title, 'Second');
      expect(handler.mediaItem.value?.artUri, Uri.file('/cover-2.png'));
      await controller.clear();
      expect(handler.mediaItem.value, isNull);
    },
  );

  testWidgets(
    'full player opens queue and fits narrow screens with scaled text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() => controller.playQueue([item]));
      for (final size in [
        const Size(320, 640),
        const Size(640, 360),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: NowPlayingPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('正在播放'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('播放队列'));
      await tester.pumpAndSettle();
      expect(find.text('播放队列为空'), findsNothing);
      expect(find.text('测试曲目'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'active and failed playback fit phone, landscape and desktop layouts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() => controller.playQueue([item]));
      for (final size in [
        const Size(320, 640),
        const Size(640, 360),
        const Size(1280, 720),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              bottomNavigationBar: PlayerBar(controller: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('测试曲目'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          engines.last._emit(const PlaybackState(error: '音频解码失败，请重新下载后重试。'));
          await _tick();
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() => controller.playQueue([item]));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'system commands publish metadata, duration, position and modes',
    () async {
      await controller.playQueue([item, item]);
      await _tick();
      expect(handler.mediaItem.value?.title, '测试曲目');
      expect(handler.mediaItem.value?.duration, const Duration(seconds: 30));
      expect(handler.queue.value.map((item) => item.id).toSet().length, 2);
      await handler.pause();
      await handler.pause();
      expect(controller.state.playing, isFalse);
      await handler.seek(const Duration(seconds: 5));
      await handler.play();
      await handler.play();
      await handler.skipToNext();
      await _tick();
      expect(handler.playbackState.value.queueIndex, 1);
      await handler.setRepeatMode(system.AudioServiceRepeatMode.one);
      expect(controller.mode, PlaybackMode.repeatOne);
      await handler.setShuffleMode(system.AudioServiceShuffleMode.all);
      expect(controller.mode, PlaybackMode.shuffle);
      await handler.stop();
      await _tick();
      expect(handler.mediaItem.value, isNotNull);
      expect(
        handler.playbackState.value.processingState,
        system.AudioProcessingState.idle,
      );
      expect(engines.every((engine) => engine.disposed), isTrue);
    },
  );
  test(
    'focus denial keeps the decoder paused and reports a retryable error',
    () async {
      allowFocus = false;
      await controller.playQueue([item]);
      expect(controller.state.playing, isFalse);
      expect(controller.state.error, contains('音频焦点'));
      expect(engines.single.played, isFalse);
      allowFocus = true;
      await handler.play();
      expect(controller.state.playing, isTrue);
    },
  );
  test(
    'transient interruption resumes only the interrupted playback',
    () async {
      await controller.playQueue([item]);
      interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _tick();
      expect(controller.state.playing, isFalse);
      interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _tick();
      expect(controller.state.playing, isTrue);
    },
  );
  test('user pause during interruption prevents automatic resume', () async {
    await controller.playQueue([item]);
    interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await _tick();
    await handler.pause();
    interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await _tick();
    expect(controller.state.playing, isFalse);
    expect(activations.last, isFalse);
  });
  test(
    'ducking preserves user volume changes and restores the current volume',
    () async {
      await controller.playQueue([item]);
      await controller.setVolume(60);
      interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await _tick();
      expect(engines.single.volume, 12);
      await controller.setVolume(40);
      expect(engines.single.volume, 8);
      interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      await _tick();
      expect(controller.volume, 40);
      expect(engines.single.volume, 40);
    },
  );
  test(
    'headphones disconnected during interruption cancel automatic resume',
    () async {
      await controller.playQueue([item]);
      interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      noisy.add(null);
      interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _tick();
      expect(controller.state.playing, isFalse);
    },
  );
  test(
    'notification stop retains queue and position and play resumes',
    () async {
      await controller.playQueue([item]);
      engines.single._emit(
        const PlaybackState(
          playing: true,
          position: Duration(seconds: 4),
          duration: Duration(seconds: 10),
        ),
      );
      await handler.stop();
      expect(controller.queue, hasLength(1));
      expect(controller.current, item);
      expect(controller.state.position, const Duration(seconds: 4));
      expect(engines.single.disposed, isTrue);
      await handler.play();
      expect(engines.length, 2);
      expect(controller.state.error, isNull);
      expect(controller.playRequested, isTrue);
      expect(controller.state.position, const Duration(seconds: 4));
    },
  );

  test(
    'task dismissal releases playback and retains the restorable queue',
    () async {
      await controller.playQueue([item]);
      await handler.onTaskRemoved();
      await _tick();
      expect(controller.queue, hasLength(1));
      expect(handler.playbackState.value.playing, isFalse);
      expect(activations.last, isFalse);
    },
  );
  test(
    'shutdown waits for focus acquisition and abandons a late grant',
    () async {
      await focus.dispose();
      activations.clear();
      final grant = Completer<bool>();
      focus = PlaybackAudioSession(
        controller: controller,
        setActive: (active) {
          activations.add(active);
          return active ? grant.future : Future.value(true);
        },
        interruptions: interruptions.stream,
        becomingNoisy: noisy.stream,
      );
      final opening = controller.playQueue([item]);
      await _tick();
      final shutdown = focus.dispose();
      grant.complete(true);
      await Future.wait([opening, shutdown]);
      expect(activations.last, isFalse);
      expect(engines.single.played, isFalse);
    },
  );
  test(
    'authorization removal stops playback and clears system metadata',
    () async {
      await controller.playQueue([item]);
      await controller.releaseFile(item.path);
      await _tick();
      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(engines.single.disposed, isTrue);
    },
  );
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 20));

class _Engine implements PlaybackEngine {
  final _events = StreamController<PlaybackState>.broadcast(sync: true);
  PlaybackState _state = const PlaybackState(duration: Duration(seconds: 30));
  double volume = 100;
  bool played = false;
  bool disposed = false;
  void _emit(PlaybackState state) {
    _state = state;
    _events.add(state);
  }

  @override
  Stream<PlaybackState> get states => _events.stream;
  @override
  Future<void> open(String path) async => _emit(_state);
  @override
  Future<void> play() async {
    played = true;
    _emit(_state.copyWith(playing: true));
  }

  @override
  Future<void> pause() async => _emit(_state.copyWith(playing: false));
  @override
  Future<void> seek(Duration position) async =>
      _emit(_state.copyWith(position: position));
  @override
  Future<void> setVolume(double volume) async => this.volume = volume;
  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}
