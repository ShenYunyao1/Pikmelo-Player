import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../../playback/models/playback_state.dart';
import '../../playback/playback_engine.dart';

class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine() {
    MediaKit.ensureInitialized();
    _player = Player();
    _subscriptions.addAll([
      _player.stream.playing.listen(
        (value) => _emit(_state.copyWith(playing: value)),
      ),
      _player.stream.buffering.listen(
        (value) => _emit(_state.copyWith(buffering: value)),
      ),
      _player.stream.position.listen(
        (value) => _emit(_state.copyWith(position: value)),
      ),
      _player.stream.duration.listen(
        (value) => _emit(_state.copyWith(duration: value)),
      ),
      _player.stream.completed.listen(
        (value) => _emit(_state.copyWith(completed: value)),
      ),
      _player.stream.error.listen(
        (value) => _emit(_state.copyWith(error: value, playing: false)),
      ),
    ]);
  }

  late final Player _player;
  final _states = StreamController<PlaybackState>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  PlaybackState _state = const PlaybackState();
  bool _disposed = false;

  void _emit(PlaybackState state) {
    if (!_disposed) {
      _state = state;
      _states.add(state);
    }
  }

  @override
  Stream<PlaybackState> get states => _states.stream;
  @override
  Future<void> open(String path) => _player.open(
    Media(path.startsWith('content://') ? path : File(path).uri.toString()),
    play: false,
  );
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    await _player.dispose();
    await _states.close();
  }
}
