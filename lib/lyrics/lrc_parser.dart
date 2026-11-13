import 'dart:convert';

import 'models/lyric_document.dart';

final _timestamp = RegExp(r'^\[(\d{1,5}):([0-5]\d)(?:[.:](\d{1,3}))?\]');
final _offset = RegExp(r'^\[offset:([+-]?\d+)\]$', caseSensitive: false);
final _metadata = RegExp(r'^\[[a-z][a-z0-9_]*:', caseSensitive: false);

LyricDocument? parseLyrics(String? value, LyricsSource source) {
  if (value == null || value.trim().isEmpty) return null;
  if (value.length > 2 * 1024 * 1024 ||
      utf8.encode(value).length > 2 * 1024 * 1024) {
    throw const FormatException('歌词超过 2 MiB 限制');
  }
  final lines = value
      .replaceFirst(RegExp(r'^\ufeff'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (lines.length > 20000) throw const FormatException('歌词行数超过限制');
  var offset = 0;
  for (final line in lines) {
    final match = _offset.firstMatch(line.trim());
    final number = int.tryParse(match?.group(1) ?? '');
    if (number != null && number.abs() <= 86400000) offset = number;
  }
  final timed = <({int time, String text, int order})>[];
  final plain = <String>[];
  for (final line in lines) {
    var text = line.trim().replaceAll('\u0000', '');
    if (_metadata.hasMatch(text)) continue;
    final times = <int>[];
    RegExpMatch? match;
    while ((match = _timestamp.firstMatch(text)) != null) {
      final current = match!;
      times.add(
        (int.parse(current.group(1)!) * 60 + int.parse(current.group(2)!)) *
                1000 +
            int.parse((current.group(3) ?? '').padRight(3, '0')) -
            offset,
      );
      text = text.substring(current.end);
      if (times.length + timed.length > 20000) {
        throw const FormatException('歌词行数超过限制');
      }
    }
    text = text.trim();
    if (times.isEmpty) {
      plain.add(text);
    } else {
      for (final time in times) {
        timed.add((time: time, text: text, order: timed.length));
      }
    }
  }
  if (!timed.any((line) => line.text.isNotEmpty)) {
    final content = plain.join('\n').trim();
    return content.isEmpty
        ? null
        : LyricDocument(source: source, cues: [], plainText: content);
  }
  timed.sort(
    (a, b) => a.time == b.time
        ? a.order.compareTo(b.order)
        : a.time.compareTo(b.time),
  );
  final cues = <LyricCue>[];
  for (var index = 0; index < timed.length;) {
    final time = timed[index].time;
    final texts = <String>{};
    while (index < timed.length && timed[index].time == time) {
      if (timed[index].text.isNotEmpty) texts.add(timed[index].text);
      index++;
    }
    cues.add(
      LyricCue(
        start: Duration(milliseconds: time),
        text: texts.firstOrNull ?? '',
        parallelText: texts.skip(1),
      ),
    );
  }
  return LyricDocument(
    source: source,
    cues: cues,
    plainText: [
      ...cues.map((cue) => cue.text),
      ...plain.where((text) => text.isNotEmpty),
    ].join('\n'),
  );
}
