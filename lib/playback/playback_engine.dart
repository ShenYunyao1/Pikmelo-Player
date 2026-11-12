import 'models/playback_state.dart';

abstract interface class PlaybackEngine {
  Stream<PlaybackState> get states;
  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}
