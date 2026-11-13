import 'package:flutter/material.dart';

import '../models/playback_item.dart';
import '../models/playback_state.dart';
import '../playback_controller.dart';

String playbackTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class PlaybackProgress extends StatefulWidget {
  const PlaybackProgress({super.key, required this.controller});
  final PlaybackController controller;
  @override
  State<PlaybackProgress> createState() => _PlaybackProgressState();
}

class _PlaybackProgressState extends State<PlaybackProgress> {
  double? _drag;
  PlaybackItem? _item;
  @override
  Widget build(BuildContext context) {
    final player = widget.controller;
    if (!identical(_item, player.current)) {
      _drag = null;
      _item = player.current;
    }
    final total = player.state.duration.inMilliseconds.toDouble();
    final enabled = total > 0 && !player.loading;
    final position = (_drag ?? player.state.position.inMilliseconds.toDouble())
        .clamp(0.0, total > 0 ? total : 1.0);
    return Row(
      children: [
        Text(
          playbackTime(Duration(milliseconds: position.toInt())),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Expanded(
          child: Slider(
            // Rebuild semantics when enabled changes (Flutter #193706).
            key: ValueKey(enabled),
            label: '播放进度',
            semanticFormatterCallback: (value) =>
                '播放进度 ${playbackTime(Duration(milliseconds: value.toInt()))}，共 ${playbackTime(player.state.duration)}',
            value: position,
            max: total > 0 ? total : 1,
            onChanged: enabled
                ? (value) => setState(() => _drag = value)
                : null,
            onChangeEnd: enabled
                ? (value) {
                    setState(() => _drag = null);
                    player.seek(Duration(milliseconds: value.toInt()));
                  }
                : null,
          ),
        ),
        Text(
          playbackTime(player.state.duration),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    required this.controller,
    this.expanded = false,
  });
  final PlaybackController controller;
  final bool expanded;
  @override
  Widget build(BuildContext context) {
    final player = controller;
    final (label, icon) = switch (player.mode) {
      PlaybackMode.sequence => ('顺序播放', Icons.playlist_play),
      PlaybackMode.repeatAll => ('列表循环', Icons.repeat),
      PlaybackMode.repeatOne => ('单曲循环', Icons.repeat_one),
      PlaybackMode.shuffle => ('随机播放', Icons.shuffle),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (expanded)
          IconButton(
            tooltip: label,
            icon: Icon(icon),
            onPressed: () => player.setMode(
              PlaybackMode.values[(player.mode.index + 1) %
                  PlaybackMode.values.length],
            ),
          ),
        IconButton(
          tooltip: '上一首',
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : player.previous,
        ),
        if (!expanded) const SizedBox(width: 8),
        IconButton.filled(
          tooltip: player.state.playing ? '暂停' : '播放',
          iconSize: expanded ? 32 : 26,
          padding: EdgeInsets.all(expanded ? 16 : 10),
          onPressed: player.queue.isEmpty || player.loading
              ? null
              : player.toggle,
          icon: Icon(
            player.state.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
        ),
        if (!expanded) const SizedBox(width: 8),
        IconButton(
          tooltip: '下一首',
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.queue.isEmpty ? null : player.next,
        ),
      ],
    );
  }
}
