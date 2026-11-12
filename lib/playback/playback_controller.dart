import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/playback_item.dart';
import 'models/playback_state.dart';
import 'playback_engine.dart';

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.createEngine,
    required this.isAvailable,
    Random? random,
  }) : _random = random ?? Random();

  final PlaybackEngine Function() createEngine;
  final bool Function(PlaybackItem item) isAvailable;
  final Random _random;
  Future<bool> Function()? requestAudioFocus;
  Future<String> Function(PlaybackItem item)? resolveSource;
  VoidCallback? cancelPreparation;
  String? _systemError;
  String? get systemError => _systemError;

  void reportSystemError(String message) {
    if (_disposed || _systemError == message) return;
    _systemError = message;
    _notify();
  }

  List<PlaybackItem> _queue = const [];
  final _history = <PlaybackItem>[];
  final _shuffleBag = <PlaybackItem>[];
  PlaybackEngine? _engine;
  String? _enginePath;
  StreamSubscription<PlaybackState>? _subscription;
  PlaybackState _state = const PlaybackState();
  PlaybackMode _mode = PlaybackMode.sequence;
  int _index = -1;
  int _version = 0;
  double _volume = 100;
  bool _loading = false;
  bool _playRequested = false;
  bool _ducked = false;
  int _transportRevision = 0;
  bool _completionHandled = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void> _commands = Future.value();
  Future<void>? _shutdown;

  List<PlaybackItem> get queue => _queue;
  int get currentIndex => _index;
  PlaybackItem? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  PlaybackState get state => _state;
  PlaybackMode get mode => _mode;
  double get volume => _volume;
  bool get loading => _loading;
  bool get playRequested => _playRequested;
  int get transportRevision => _transportRevision;

  Future<void> playQueue(List<PlaybackItem> items, {int index = 0}) {
    if (_disposed) return Future.value();
    _queue = List.unmodifiable(items);
    _history.clear();
    _shuffleBag.clear();
    return jump(index);
  }

  Future<void> jump(int index, {bool play = true}) {
    if (_disposed) return Future.value();
    cancelPreparation?.call();
    _transportRevision++;
    _playRequested = play;
    final version = ++_version;
    final candidates = _queue.asMap().entries.where(
      (entry) => entry.key >= index && _available(entry.value),
    );
    if (index < 0 || candidates.isEmpty) {
      _index = -1;
      _playRequested = false;
      _loading = false;
      _state = const PlaybackState(error: '队列中没有可用的本地音频。');
      _notify();
      return _schedule(version, _releaseEngine);
    }
    _index = candidates.first.key;
    final item = _queue[_index];
    _loading = true;
    _completionHandled = false;
    _state = const PlaybackState(buffering: true);
    _notify();
    return _schedule(version, () async {
      await _releaseEngine();
      if (!_current(version)) return;
      if (!_available(item)) {
        throw StateError('The local source is unavailable.');
      }
      final path = await resolveSource?.call(item) ?? item.path;
      if (!_current(version)) return;
      if (path != item.path) {
        final resolved = PlaybackItem(
          serverUri: item.serverUri,
          track: item.track,
          path: path,
        );
        _queue = List.unmodifiable([..._queue]..[_index] = resolved);
      }
      final engine = createEngine();
      _engine = engine;
      _enginePath = path;
      _subscription = engine.states.listen((state) {
        if (!_current(version)) return;
        _state = state.error == null
            ? state
            : state.copyWith(playing: false, buffering: false);
        if (state.error != null && !_completionHandled) {
          _playRequested = false;
          _completionHandled = true;
          _loading = false;
          unawaited(_schedule(version, _releaseEngine));
        }
        _notify();
        _advanceWhenCompleted();
      });
      await engine.open(path).timeout(const Duration(seconds: 20));
      if (!_current(version) || _state.error != null) return;
      await engine.setVolume(_effectiveVolume);
      if (!_current(version)) return;
      if (_playRequested) await _playEngine(version);
      if (!_current(version)) return;
      _loading = false;
      _notify();
      _advanceWhenCompleted();
    });
  }

  Future<void> toggle() {
    return _playRequested ? pause() : play();
  }

  Future<void> play() {
    if (_disposed) return Future.value();
    _transportRevision++;
    _playRequested = true;
    final item = current;
    if (item == null) return jump(0);
    if (!_available(item)) return reconcile();
    if (_engine == null || _state.completed || _state.error != null) {
      return jump(_index);
    }
    final version = _version;
    return _schedule(version, () => _playEngine(version));
  }

  Future<void> pause() {
    if (_disposed) return Future.value();
    _transportRevision++;
    _playRequested = false;
    return _schedule(_version, () async {
      await _engine?.pause();
      _notify();
    });
  }

  Future<void> _playEngine(int version) async {
    final allowed = await requestAudioFocus?.call() ?? true;
    if (!_current(version) || !_playRequested) return;
    if (!allowed) {
      _playRequested = false;
      _state = PlaybackState(
        position: _state.position,
        duration: _state.duration,
        error: '无法取得音频焦点，请稍后重试。',
      );
      _notify();
      return;
    }
    await _engine?.play();
  }

  Future<void> seek(Duration position) {
    final duration = _state.duration;
    final milliseconds = position.inMilliseconds.clamp(
      0,
      duration > Duration.zero
          ? duration.inMilliseconds
          : position.inMilliseconds.abs(),
    );
    return _schedule(_version, () async {
      _completionHandled = false;
      _state = _state.copyWith(completed: false);
      await _engine?.seek(Duration(milliseconds: milliseconds));
    });
  }

  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0, 100);
    _notify();
    return _schedule(_version, () async {
      await _engine?.setVolume(_effectiveVolume);
    });
  }

  double get _effectiveVolume => _volume * (_ducked ? 0.2 : 1);

  Future<void> setDucked(bool ducked) {
    _ducked = ducked;
    return _schedule(_version, () async {
      await _engine?.setVolume(_effectiveVolume);
    });
  }

  void setMode(PlaybackMode mode) {
    _mode = mode;
    _shuffleBag.clear();
    _history.clear();
    _notify();
  }

  Future<void> next({bool automatic = false}) {
    if (_disposed || _queue.isEmpty) return Future.value();
    if (automatic && _mode == PlaybackMode.repeatOne) return jump(_index);
    final item = current;
    if (item != null) _history.add(item);
    if (_mode == PlaybackMode.shuffle) {
      _shuffleBag.removeWhere(
        (candidate) => identical(candidate, item) || !_available(candidate),
      );
      if (_shuffleBag.isEmpty) {
        _shuffleBag.addAll(
          _queue.where(
            (candidate) => !identical(candidate, item) && _available(candidate),
          ),
        );
        _shuffleBag.shuffle(_random);
      }
      if (_shuffleBag.isNotEmpty) {
        return jump(_queue.indexOf(_shuffleBag.removeLast()));
      }
      return jump(_index >= 0 ? _index : 0);
    }
    if (_index + 1 < _queue.length) return jump(_index + 1);
    if (_mode == PlaybackMode.repeatAll) return jump(0);
    _state = _state.copyWith(playing: false, completed: true);
    _playRequested = false;
    _notify();
    return _schedule(_version, () async {
      await _engine?.pause();
    });
  }

  PlaybackItem? get upcoming {
    if (_queue.isEmpty || _index < 0) return null;
    if (_mode == PlaybackMode.repeatOne) return current;
    if (_mode == PlaybackMode.shuffle) {
      _shuffleBag.removeWhere(
        (item) => identical(item, current) || !_available(item),
      );
      if (_shuffleBag.isEmpty) {
        _shuffleBag.addAll(
          _queue.where((item) => !identical(item, current) && _available(item)),
        );
        _shuffleBag.shuffle(_random);
      }
      return _shuffleBag.isEmpty ? current : _shuffleBag.last;
    }
    final candidates = _queue.skip(_index + 1).where(_available);
    if (candidates.isNotEmpty) return candidates.first;
    if (_mode == PlaybackMode.repeatAll) {
      final available = _queue.where(_available);
      return available.isEmpty ? null : available.first;
    }
    return null;
  }

  Future<void> previous() {
    if (_mode == PlaybackMode.shuffle && _history.isNotEmpty) {
      return jump(_queue.indexOf(_history.removeLast()));
    }
    final index = _index > 0
        ? _index - 1
        : _mode == PlaybackMode.repeatAll
        ? _queue.length - 1
        : 0;
    return jump(index);
  }

  Future<void> clear() {
    cancelPreparation?.call();
    _transportRevision++;
    _playRequested = false;
    final version = ++_version;
    _queue = const [];
    _index = -1;
    _history.clear();
    _shuffleBag.clear();
    _loading = false;
    _state = const PlaybackState();
    _notify();
    return _schedule(version, _releaseEngine);
  }

  Future<void> releaseFile(String path) async {
    await _retain((item) => item.path != path);
    await _releasePath(path);
  }

  Future<void> reconcile() async {
    final item = current;
    await _retain(_available);
    if (item != null && !_available(item)) await _releasePath(item.path);
  }

  Future<void> _releasePath(String path) async {
    if (_disposed) {
      await shutdown();
      return;
    }
    final result = _commands.then((_) async {
      if (_enginePath == path) await _releaseEngine();
    });
    _commands = result;
    await result;
  }

  Future<void> _retain(bool Function(PlaybackItem) keep) {
    final item = current;
    final retained = _queue.where(keep).toList(growable: false);
    if (retained.length == _queue.length) return Future.value();
    _queue = List.unmodifiable(retained);
    _history.removeWhere((item) => !retained.contains(item));
    _shuffleBag.removeWhere((item) => !retained.contains(item));
    _index = item == null ? -1 : retained.indexOf(item);
    _notify();
    if (item == null || _index >= 0) return Future.value();
    final version = ++_version;
    _loading = false;
    cancelPreparation?.call();
    _playRequested = false;
    _state = const PlaybackState(error: '本地音源已移除或授权已更新，播放已停止。');
    _notify();
    return _schedule(version, _releaseEngine);
  }

  bool _available(PlaybackItem item) {
    try {
      return isAvailable(item);
    } catch (_) {
      return false;
    }
  }

  void _advanceWhenCompleted() {
    if (!_loading &&
        _state.completed &&
        _state.error == null &&
        !_completionHandled) {
      _completionHandled = true;
      unawaited(next(automatic: true));
    }
  }

  Future<void> _schedule(int version, Future<void> Function() operation) {
    final result = _commands.then((_) async {
      if (!_current(version)) return;
      try {
        await operation();
      } catch (error) {
        if (_current(version)) {
          _playRequested = false;
          _loading = false;
          _state = PlaybackState(
            error: error is PlaybackPreparationException
                ? error.message
                : '无法播放该音频，请检查文件或切换曲目。',
          );
          try {
            await _releaseEngine();
          } catch (_) {
            /* The failure remains visible in playback state. */
          }
          _notify();
        }
      }
    });
    _commands = result;
    return result;
  }

  Future<void> _releaseEngine() async {
    final engine = _engine;
    _engine = null;
    await _subscription?.cancel();
    _subscription = null;
    await engine?.dispose();
    _enginePath = null;
  }

  bool _current(int version) => !_disposed && version == _version;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> shutdown() {
    final pending = _shutdown;
    if (pending != null) return pending;
    _disposed = true;
    cancelPreparation?.call();
    _version++;
    final result = _commands.then((_) => _releaseEngine());
    _commands = result;
    _shutdown = result;
    return result;
  }

  @override
  void dispose() {
    unawaited(shutdown());
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}

class PlaybackPreparationException implements Exception {
  const PlaybackPreparationException(this.message);
  final String message;
}
