enum LyricsSource { embedded, server }

class LyricCue {
  LyricCue({
    required this.start,
    required this.text,
    Iterable<String> parallelText = const [],
  }) : parallelText = List.unmodifiable(parallelText);
  final Duration start;
  final String text;
  final List<String> parallelText;
}

class LyricDocument {
  LyricDocument({
    required this.source,
    required Iterable<LyricCue> cues,
    required this.plainText,
  }) : cues = List.unmodifiable(cues);
  final LyricsSource source;
  final List<LyricCue> cues;
  final String plainText;
  bool get synchronized => cues.isNotEmpty;
  int indexAt(Duration position) {
    var low = 0, high = cues.length - 1, index = -1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (cues[middle].start <= position) {
        index = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return index;
  }
}

class LyricsUnavailable implements Exception {
  const LyricsUnavailable();
}
