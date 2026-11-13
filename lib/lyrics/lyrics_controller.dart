import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/playback_controller.dart';
import '../playback/models/playback_item.dart';
import 'models/lyric_document.dart';
import '../shared/diagnostics.dart';

class LyricsController extends ChangeNotifier {
  LyricsController(this.player) {
    player.addListener(_changed);
    _changed();
  }
  final PlaybackController player;
  PlaybackItem? _item;
  Object? _loader;
  int _revision = -1, _generation = 0, _seekRevision = -1;
  bool _disposed = false, _pendingSeek = false, _advancing = false;
  Duration? _reported;
  Duration _anchor = Duration.zero;
  final _elapsed = Stopwatch();
  Timer? _timer;
  LyricDocument? document;
  bool loading = false, unavailable = false, snap = true;
  int index = -1;

  void _changed() {
    if (_disposed) return;
    final advancing =
        player.state.playing &&
        !player.state.buffering &&
        !player.loading &&
        !player.stopped;
    final position = player.state.position;
    _pendingSeek |= _seekRevision != player.seekRevision;
    _seekRevision = player.seekRevision;
    final moved = _reported != position;
    final jumped =
        moved &&
        (_pendingSeek ||
            _reported != null &&
                ((position - _reported!).isNegative ||
                    (position - _reported!).abs() >
                        const Duration(seconds: 1)));
    if (moved || advancing != _advancing) {
      // The final paused position can follow the playing=false event.
      // Freeze the current interpolation until that position arrives.
      _anchor = moved || advancing || player.stopped ? position : _position;
      _elapsed.reset();
      if (advancing) {
        _elapsed.start();
      } else {
        _elapsed.stop();
      }
    }
    if (moved) _pendingSeek = false;
    _reported = position;
    final activityChanged = advancing != _advancing;
    _advancing = advancing;
    if (!identical(_item, player.current) ||
        _revision != player.lyricsRevision ||
        _loader != player.loadLyrics) {
      _item = player.current;
      _revision = player.lyricsRevision;
      _loader = player.loadLyrics;
      _reload();
      return;
    }
    _locate(jump: jumped, force: activityChanged);
  }

  void _reload() {
    final generation = ++_generation;
    _timer?.cancel();
    document = null;
    index = -1;
    snap = true;
    unavailable = false;
    final item = _item, load = player.loadLyrics;
    loading = item != null && load != null;
    notifyListeners();
    if (!loading) return;
    Future<LyricDocument?>.sync(() => load!(item!)).then<void>(
      (value) {
        if (_disposed || generation != _generation) return;
        Diagnostics.event('lyrics.presentation.ready', {
          'cues': value?.cues.length ?? 0,
        });
        document = value;
        loading = false;
        _locate(jump: true, force: true);
      },
      onError: (Object error, StackTrace stack) {
        if (_disposed || generation != _generation) return;
        Diagnostics.event('lyrics.presentation.failed', {
          'errorType': error.runtimeType.toString(),
        });
        loading = false;
        unavailable = true;
        notifyListeners();
      },
    );
  }

  Duration get _position {
    final position = _anchor + (_advancing ? _elapsed.elapsed : Duration.zero);
    final duration = player.state.duration;
    return duration > Duration.zero && position > duration
        ? duration
        : position;
  }

  void _locate({bool jump = false, bool force = false}) {
    _timer?.cancel();
    final doc = document;
    if (doc == null || !doc.synchronized) {
      if (force) notifyListeners();
      return;
    }
    final nextIndex = player.state.completed
        ? doc.cues.length
        : doc.indexAt(_position);
    if (nextIndex != index || force) {
      snap = jump || nextIndex != index + 1;
      index = nextIndex;
      Diagnostics.event('lyrics.position', {
        'index': index,
        'engineMs': player.state.position.inMilliseconds,
        'projectedMs': _position.inMilliseconds,
        'snap': snap,
        'advancing': _advancing,
      });
      notifyListeners();
    }
    if (!_advancing || index + 1 >= doc.cues.length) return;
    final wait = doc.cues[index + 1].start - _position;
    _timer = Timer(
      wait > const Duration(milliseconds: 1)
          ? wait
          : const Duration(milliseconds: 1),
      () => _locate(),
    );
  }

  void retry() => player.invalidateLyrics();
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _elapsed.stop();
    player.removeListener(_changed);
    super.dispose();
  }
}
