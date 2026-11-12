import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../../playback/playback_controller.dart';

class PlaybackAudioSession {
  PlaybackAudioSession({
    required this.controller,
    required this.setActive,
    required Stream<AudioInterruptionEvent> interruptions,
    required Stream<void> becomingNoisy,
  }) {
    controller.requestAudioFocus = _activate;
    controller.addListener(_onPlaybackChanged);
    _subscriptions.add(interruptions.listen(_onInterruption));
    _subscriptions.add(becomingNoisy.listen((_) => _onNoisy()));
  }

  final PlaybackController controller;
  final Future<bool> Function(bool active) setActive;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  int? _resumeRevision;
  bool _interrupted = false;
  bool _active = false;
  bool _disposed = false;
  Future<void> _operations = Future.value();
  Future<void>? _shutdown;

  Future<bool> _activate() {
    final result = _operations.then((_) async {
      if (_disposed) return false;
      try {
        final allowed = await setActive(true);
        if (_disposed || !controller.playRequested) {
          await _deactivate();
          return false;
        }
        _active = allowed;
        if (allowed) {
          _resumeRevision = null;
          _interrupted = false;
        }
        return allowed;
      } catch (_) {
        controller.reportSystemError('音频会话不可用，请稍后重试。');
        return false;
      }
    });
    _operations = result.then((_) {});
    return result;
  }

  void _onPlaybackChanged() {
    if (!_disposed && _active && !controller.playRequested && !_interrupted) {
      _active = false;
      _operations = _operations.then((_) => _deactivate());
    }
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (_disposed) return;
    if (event.type == AudioInterruptionType.duck) {
      unawaited(controller.setDucked(event.begin));
      return;
    }
    if (event.begin) {
      if (_interrupted) return;
      _interrupted = true;
      unawaited(controller.setDucked(false));
      final resume = controller.playRequested;
      unawaited(controller.pause());
      _resumeRevision = resume ? controller.transportRevision : null;
    } else {
      _interrupted = false;
      final revision = _resumeRevision;
      _resumeRevision = null;
      if (event.type == AudioInterruptionType.pause &&
          revision != null &&
          revision == controller.transportRevision) {
        unawaited(controller.play());
      } else {
        _onPlaybackChanged();
      }
    }
  }

  void _onNoisy() {
    _resumeRevision = null;
    _interrupted = false;
    unawaited(controller.setDucked(false));
    unawaited(controller.pause());
  }

  Future<void> dispose() => _shutdown ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    controller.removeListener(_onPlaybackChanged);
    controller.requestAudioFocus = null;
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    await _operations;
    await _deactivate();
  }

  Future<void> _deactivate() async {
    try {
      await setActive(false);
    } catch (_) {
      controller.reportSystemError('音频焦点释放失败，请重启应用后重试。');
    }
  }
}
