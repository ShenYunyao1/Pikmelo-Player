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
import 'package:pikmelo_player/playback/ui/now_playing_page.dart';
import 'package:pikmelo_player/playback/ui/playback_controls.dart';

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
