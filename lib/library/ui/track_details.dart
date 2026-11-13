import 'package:flutter/material.dart';

import '../../playback/ui/playback_controls.dart';
import '../models/track.dart';

Future<void> showTrackDetails(
  BuildContext context,
  Track track, {
  Future<Track?> Function()? load,
}) => _showDetails(context, track, load);

Future<void> _showDetails(
  BuildContext context,
  Track trackFallback,
  Future<Track?> Function()? load,
) {
  final future = load?.call();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FutureBuilder<Track?>(
      future: future,
      initialData: trackFallback,
      builder: (context, snapshot) {
        final track = snapshot.data ?? trackFallback;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('曲目信息', style: Theme.of(context).textTheme.titleLarge),
                  for (final entry in <String, String?>{
                    '来源': snapshot.connectionState == ConnectionState.waiting
                        ? '正在读取本地音频'
                        : track.parsedLocally
                        ? '本地音频解析'
                        : '已同步信息',
                    '曲名': track.title,
                    '歌手': track.artist ?? '未知',
                    '专辑': track.album ?? '未知',
                    '时长': track.duration == null
                        ? '未知'
                        : playbackTime(track.duration!),
                    '格式': track.format?.toUpperCase() ?? '未知',
                    '文件大小': track.size == null || track.size! < 0
                        ? null
                        : '${(track.size! / 1024 / 1024).toStringAsFixed(2)} MB',
                    '码率': track.bitrateKbps == null
                        ? '未知'
                        : '${track.bitrateKbps} kbps',
                    '采样率': track.sampleRate == null
                        ? '未知'
                        : '${track.sampleRate} Hz',
                    '声道': track.channels?.toString() ?? '未知',
                    '位深': track.bitsPerSample == null
                        ? '未知'
                        : '${track.bitsPerSample} bit',
                    '流派': track.genre,
                    '备注': track.comment,
                  }.entries)
                    if (entry.value != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText('${entry.key}　${entry.value}'),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

String playlistDurationLabel(Iterable<Track?> tracks) {
  var known = 0;
  var unknown = 0;
  var duration = Duration.zero;
  for (final track in tracks) {
    final value = track?.duration;
    if (value == null) {
      unknown++;
    } else {
      known++;
      duration += value;
    }
  }
  if (known == 0) return unknown == 0 ? '' : '时长未知';
  return unknown == 0
      ? '总时长 ${playbackTime(duration)}'
      : '已知时长 ${playbackTime(duration)} · $unknown 首时长未知';
}
