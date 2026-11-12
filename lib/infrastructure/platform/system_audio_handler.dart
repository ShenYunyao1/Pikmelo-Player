import 'package:audio_service/audio_service.dart';

import '../../playback/models/playback_state.dart' as local;
import '../../playback/playback_controller.dart';

class SystemAudioHandler extends BaseAudioHandler {
  PlaybackController? _controller;
  Object? _publishedQueue;

  void attach(PlaybackController? controller) {
    _controller?.removeListener(_publish);
    _controller = controller;
    _publishedQueue = null;
    controller?.addListener(_publish);
    _publish();
  }

  void _publish() {
    final controller = _controller;
    if (controller == null) {
      queue.add(const []);
      mediaItem.add(null);
      playbackState.add(PlaybackState());
      return;
    }
    if (!identical(_publishedQueue, controller.queue)) {
      _publishedQueue = controller.queue;
      queue.add([
        for (var index = 0; index < controller.queue.length; index++)
          MediaItem(
            id: '${controller.queue[index].serverUri}#${controller.queue[index].track.id}#$index',
            title: controller.queue[index].track.title,
            artist: controller.queue[index].track.artist,
          ),
      ]);
    }
    final state = controller.state;
    final index = controller.currentIndex;
    final current = controller.current;
    final item = current == null
        ? null
        : queue.value[index].copyWith(duration: state.duration);
    final previous = mediaItem.value;
    if (previous?.id != item?.id ||
        previous?.duration != item?.duration ||
        previous?.title != item?.title ||
        previous?.artist != item?.artist) {
      mediaItem.add(item);
    }
    final processing = current == null
        ? AudioProcessingState.idle
        : state.error != null
        ? AudioProcessingState.error
        : controller.loading
        ? AudioProcessingState.loading
        : state.buffering
        ? AudioProcessingState.buffering
        : state.completed
        ? AudioProcessingState.completed
        : AudioProcessingState.ready;
    playbackState.add(
      PlaybackState(
        controls: current == null
            ? const []
            : [
                MediaControl.skipToPrevious,
                state.playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
                MediaControl.stop,
              ],
        androidCompactActionIndices: current == null
            ? const []
            : const [0, 1, 2],
        systemActions: current == null ? const {} : const {MediaAction.seek},
        processingState: processing,
        playing: current != null && state.playing,
        updatePosition: state.position,
        bufferedPosition: state.duration,
        queueIndex: index < 0 ? null : index,
        repeatMode: switch (controller.mode) {
          local.PlaybackMode.repeatOne => AudioServiceRepeatMode.one,
          local.PlaybackMode.repeatAll => AudioServiceRepeatMode.all,
          _ => AudioServiceRepeatMode.none,
        },
        shuffleMode: controller.mode == local.PlaybackMode.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        errorCode: state.error == null ? null : 1,
        errorMessage: state.error,
      ),
    );
  }

  @override
  Future<void> play() async => _controller?.play();
  @override
  Future<void> pause() async => _controller?.pause();
  @override
  Future<void> seek(Duration position) async => _controller?.seek(position);
  @override
  Future<void> skipToNext() async => _controller?.next();
  @override
  Future<void> skipToPrevious() async => _controller?.previous();
  @override
  Future<void> skipToQueueItem(int index) async => _controller?.jump(index);
  @override
  Future<void> stop() async {
    await _controller?.clear();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() => stop();
  @override
  Future<void> onNotificationDeleted() => stop();
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _controller?.setMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => local.PlaybackMode.repeatOne,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => local.PlaybackMode.repeatAll,
      _ => local.PlaybackMode.sequence,
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode != AudioServiceShuffleMode.none) {
      _controller?.setMode(local.PlaybackMode.shuffle);
    } else if (_controller?.mode == local.PlaybackMode.shuffle) {
      _controller?.setMode(local.PlaybackMode.sequence);
    }
  }
}
