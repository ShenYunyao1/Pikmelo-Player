import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/playback_engine.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';

void main() {
  late PlaybackController controller;
  late List<_Engine> engines;
  late Set<String> missing;
  final items = List.generate(
    3,
    (i) => PlaybackItem(
      serverUri: Uri.parse('https://example.com'),
      track: Track.fromJson({'id': 'track-$i', 'title': 'Song $i'}),
      path: '/song-$i.media',
    ),
  );
  setUp(() {
    engines = [];
    missing = {};
    controller = PlaybackController(
      createEngine: () {
        final engine = _Engine();
        engines.add(engine);
        return engine;
      },
      isAvailable: (item) => !missing.contains(item.path),
      random: Random(1),
    );
  });
  tearDown(() async {
    controller.dispose();
    await controller.shutdown();
  });

  test('queue supports pause, seek, volume and previous/next', () async {
    await controller.playQueue(items, index: 1);
    expect(controller.current, items[1]);
    expect(engines.single.path, items[1].path);
    await controller.toggle();
    expect(engines.single.paused, isTrue);
    await controller.seek(const Duration(seconds: 4));
    expect(engines.single.position, const Duration(seconds: 4));
    await controller.setVolume(35);
    expect(controller.volume, 35);
    await controller.next();
    expect(controller.current, items[2]);
    expect(engines.first.disposed, isTrue);
    await controller.previous();
    expect(controller.current, items[1]);
  });
  test('pause during focus acquisition prevents delayed autoplay', () async {
    final focus = Completer<bool>();
    controller.requestAudioFocus = () => focus.future;
    final opening = controller.playQueue(items);
    await _tick();
    final pause = controller.pause();
    focus.complete(true);
    await Future.wait([opening, pause]);
    expect(engines.single.played, isFalse);
    expect(controller.state.playing, isFalse);
  });
  test('natural completion follows repeat and sequence modes', () async {
    await controller.playQueue(items, index: 2);
    engines.last.emit(const PlaybackState(completed: true));
    await _tick();
    expect(controller.current, items.last);
    expect(controller.state.playing, isFalse);
    controller.setMode(PlaybackMode.repeatAll);
    await controller.next();
    expect(controller.current, items.first);
    controller.setMode(PlaybackMode.repeatOne);
    engines.last.emit(const PlaybackState(completed: true));
    await _tick();
    expect(controller.current, items.first);
    expect(engines.length, 3);
  });
  test('rapid selections discard older commands and callbacks', () async {
    await controller.playQueue(items);
    final old = engines.first;
    final first = controller.jump(1);
    final second = controller.jump(2);
    await Future.wait([first, second]);
    expect(controller.current, items[2]);
    expect(engines.last.path, items[2].path);
    old.emit(const PlaybackState(completed: true));
    await _tick();
    expect(controller.current, items[2]);
  });

  test('changing selection cancels pending source preparation before the next command', () async {
    Completer<String>? pending;
    controller.resolveSource = (item) {
      if (item.track.id == items.first.track.id) {
        pending = Completer<String>();
        return pending!.future;
      }
      return Future.value(item.path);
    };
    controller.cancelPreparation = () {
      if (pending != null && !pending!.isCompleted) {
        pending!.completeError(const PlaybackPreparationException('cancelled'));
      }
    };
    final first = controller.playQueue(items);
    await _tick();
    expect(controller.loading, isTrue);
    final next = controller.jump(1);
    await Future.wait([first, next]);
    expect(engines.single.path, items[1].path);
    expect(controller.state.error, isNull);
  });

  test(
    'source preparation failure remains visible without opening an engine',
    () async {
      controller.resolveSource = (_) =>
          Future.error(const PlaybackPreparationException('当前网络策略禁止下载'));
      await controller.playQueue(items);
      expect(controller.state.error, '当前网络策略禁止下载');
      expect(engines, isEmpty);
      expect(controller.loading, isFalse);
    },
  );
  test(
    'missing files are skipped and file deletion releases the backend',
    () async {
      missing.add(items[0].path);
      await controller.playQueue(items);
      expect(controller.current, items[1]);
      final playing = engines.last;
      await controller.releaseFile(items[1].path);
      expect(playing.disposed, isTrue);
      expect(
        controller.queue.any((item) => item.path == items[1].path),
        isFalse,
      );
      expect(controller.current, isNull);
    },
  );
  test('authorization reconciliation stops current media and clears invalid queue entries', () async {
    await controller.playQueue(items);
    missing.addAll(items.map((item) => item.path));
    await controller.reconcile();
    expect(controller.queue, isEmpty);
    expect(controller.current, isNull);
    expect(engines.single.disposed, isTrue);
  });
  test(
    'shuffle avoids immediate repetition and previous follows history',
    () async {
      await controller.playQueue(items);
      controller.setMode(PlaybackMode.shuffle);
      await controller.next();
      expect(controller.current, isNot(items.first));
      await controller.previous();
      expect(controller.current, items.first);
    },
  );
  test('decoder errors are visible and release the active engine', () async {
    await controller.playQueue(items);
    engines.last.emit(
      const PlaybackState(error: 'Decode failed', buffering: true),
    );
    await _tick();
    expect(controller.state.error, isNotNull);
    expect(controller.state.buffering, isFalse);
    expect(engines.last.disposed, isTrue);
    await controller.next();
    expect(controller.current, items[1]);
  });
  test(
    'shuffle keeps the available track when other files disappear',
    () async {
      await controller.playQueue(items);
      controller.setMode(PlaybackMode.shuffle);
      missing.addAll(items.skip(1).map((item) => item.path));
      await controller.next();
      expect(controller.current, items.first);
      expect(controller.state.error, isNull);
    },
  );
  test('deletion waits for a pending open and releases its backend', () async {
    controller.dispose();
    await controller.shutdown();
    final opening = Completer<void>();
    controller = PlaybackController(
      createEngine: () {
        final engine = _Engine(opening: opening);
        engines.add(engine);
        return engine;
      },
      isAvailable: (_) => true,
    );
    final initial = controller.playQueue(items);
    await _tick();
    var released = false;
    final removal = controller.releaseFile(items.first.path).then((_) {
      released = true;
    });
    await _tick();
    expect(released, isFalse);
    opening.complete();
    await Future.wait([initial, removal]);
    expect(engines.single.disposed, isTrue);
    expect(engines.single.played, isFalse);
    expect(controller.current, isNull);
  });
  test('selection during a pending open ignores stale events and closes the old backend', () async {
    controller.dispose();
    await controller.shutdown();
    final opening = Completer<void>();
    controller = PlaybackController(
      createEngine: () {
        final engine = _Engine(opening: engines.isEmpty ? opening : null);
        engines.add(engine);
        return engine;
      },
      isAvailable: (_) => true,
    );
    final initial = controller.playQueue(items);
    await _tick();
    final next = controller.jump(1);
    engines.first.emit(const PlaybackState(error: 'Stale error'));
    opening.complete();
    await Future.wait([initial, next]);
    expect(engines.first.disposed, isTrue);
    expect(engines.first.played, isFalse);
    expect(controller.current, items[1]);
    expect(controller.state.error, isNull);
  });
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 10));

class _Engine implements PlaybackEngine {
  _Engine({this.opening});
  final Completer<void>? opening;
  final _states = StreamController<PlaybackState>.broadcast(sync: true);
  String? path;
  bool paused = false;
  bool played = false;
  bool disposed = false;
  Duration position = Duration.zero;
  @override
  Stream<PlaybackState> get states => _states.stream;
  void emit(PlaybackState state) {
    if (!_states.isClosed) _states.add(state);
  }

  @override
  Future<void> open(String path) async {
    this.path = path;
    emit(const PlaybackState(duration: Duration(seconds: 10)));
    await opening?.future;
  }

  @override
  Future<void> play() async {
    played = true;
    paused = false;
    emit(const PlaybackState(playing: true, duration: Duration(seconds: 10)));
  }

  @override
  Future<void> pause() async {
    paused = true;
    emit(const PlaybackState(duration: Duration(seconds: 10)));
  }

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await _states.close();
  }
}
