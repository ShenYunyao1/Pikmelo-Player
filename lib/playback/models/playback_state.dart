enum PlaybackMode { sequence, repeatAll, repeatOne, shuffle }

class PlaybackState {
  const PlaybackState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });

  final bool playing;
  final bool buffering;
  final bool completed;
  final Duration position;
  final Duration duration;
  final String? error;

  PlaybackState copyWith({
    bool? playing,
    bool? buffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    String? error,
  }) => PlaybackState(
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    error: error ?? this.error,
  );
}
