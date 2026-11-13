import 'package:audio_service/audio_service.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../playback/models/playback_state.dart' as local;
import '../../playback/playback_controller.dart';
import '../../playback/models/playback_item.dart';

class SystemAudioHandler extends BaseAudioHandler {
  SystemAudioHandler({this.saveArtwork = _saveArtwork});
  final Future<Uri> Function(Uint8List) saveArtwork;
  PlaybackItem? _artworkItem;
  Uri? _artworkUri;
  int _artworkRevision = 0;
  PlaybackController? _controller;
  Object? _publishedQueue;

  void attach(PlaybackController? controller) {
    _controller?.removeListener(_publish);
    _controller = controller;
    _publishedQueue = null;
    _artworkItem = null;
    _artworkUri = null;
    _artworkRevision++;
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
            album: controller.queue[index].track.album,
            duration: controller.queue[index].track.duration,
          ),
      ]);
    }
    final state = controller.state;
    final index = controller.currentIndex;
    final current = controller.current;
    if (!identical(current, _artworkItem)) {
      _artworkItem = current;
      _artworkUri = null;
      final revision = ++_artworkRevision;
      if (current != null && controller.loadArtwork != null) {
        unawaited(_loadArtwork(controller, current, revision));
      }
    }
    final item = current == null
        ? null
        : queue.value[index].copyWith(
            duration: state.duration > Duration.zero
                ? state.duration
                : current.track.duration,
            artUri: _artworkUri,
          );
    final previous = mediaItem.value;
    if (previous?.id != item?.id ||
        previous?.duration != item?.duration ||
        previous?.title != item?.title ||
        previous?.artist != item?.artist ||
        previous?.album != item?.album ||
        previous?.artUri != item?.artUri) {
      mediaItem.add(item);
    }
    final processing = current == null || controller.stopped
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

  Future<void> _loadArtwork(
    PlaybackController controller,
    PlaybackItem item,
    int revision,
  ) async {
    try {
      final bytes = await controller.loadArtwork!(item);
      if (bytes == null ||
          revision != _artworkRevision ||
          _controller != controller) {
        return;
      }
      final uri = await saveArtwork(bytes);
      if (revision != _artworkRevision ||
          _controller != controller ||
          !identical(controller.current, item)) {
        return;
      }
      _artworkUri = uri;
      _publish();
    } catch (_) {
      /* Media controls remain available when artwork is unavailable. */
    }
  }

  static Future<Uri> _saveArtwork(Uint8List bytes) async {
    final root = await getTemporaryDirectory();
    final directory = await Directory(
      '${root.path}/pikmelo-notification-artwork',
    ).create(recursive: true);
    final file = File('${directory.path}/${sha256.convert(bytes)}.image');
    if (!await file.exists()) {
      final partial = File(
        '${file.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.part',
      );
      try {
        await partial.writeAsBytes(bytes, flush: true);
        await partial.rename(file.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.image'))
        .cast<File>()
        .toList();
    final stats = <File, FileStat>{};
    var total = 0;
    for (final cached in files) {
      final stat = await cached.stat();
      stats[cached] = stat;
      total += stat.size;
    }
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final cached in files) {
      if (total <= 64 * 1024 * 1024) break;
      if (cached.path == file.path) continue;
      await cached.delete();
      total -= stats[cached]!.size;
    }
    return file.uri;
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
    await _controller?.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    await _controller?.stop();
    await super.stop();
  }

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
