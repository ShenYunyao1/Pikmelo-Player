import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../playback/playback_controller.dart';
import '../../playback/ui/scrolling_track_text.dart';
import '../lyrics_controller.dart';
import '../models/lyric_document.dart';

class ThreeLineLyrics extends StatefulWidget {
  const ThreeLineLyrics({super.key, required this.player});
  final PlaybackController player;
  static double heightFor(BuildContext context) =>
      math.max(120, MediaQuery.textScalerOf(context).scale(22) * 3 + 12);
  @override
  State<ThreeLineLyrics> createState() => _ThreeLineLyricsState();
}

class _ThreeLineLyricsState extends State<ThreeLineLyrics>
    with SingleTickerProviderStateMixin {
  late LyricsController _lyrics;
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  LyricDocument? _document;
  int _from = -1, _to = -1;
  bool _reduceMotion = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _animation.stop();
      _animation.value = 1;
    }
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _lyrics = LyricsController(widget.player);
    _lyrics.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(ThreeLineLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _lyrics.dispose();
      _attach();
    }
  }

  void _changed() {
    final doc = _lyrics.document;
    final animate =
        identical(doc, _document) &&
        doc != null &&
        !_lyrics.snap &&
        _lyrics.index == _to + 1;
    setState(() {
      _from = animate ? _to : _lyrics.index;
      _to = _lyrics.index;
      _document = doc;
    });
    _animation.stop();
    if (animate && !_reduceMotion) {
      final next = doc.cues.elementAtOrNull(_to + 1);
      final current = doc.cues.elementAtOrNull(_to);
      final gap = next != null && current != null
          ? (next.start - current.start).inMilliseconds
          : 650;
      _animation.duration = Duration(
        milliseconds: math.min(260, math.max(1, (gap * .4).round())),
      );
      _animation.forward(from: 0);
    } else {
      _animation.value = 1;
    }
  }

  @override
  void dispose() {
    _lyrics.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: ThreeLineLyrics.heightFor(context),
    child: RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context), doc = _lyrics.document;
          if (_lyrics.loading) {
            return Center(
              child: Text('正在读取歌词…', style: theme.textTheme.bodySmall),
            );
          }
          if (_lyrics.unavailable) {
            return Center(
              child: TextButton(
                onPressed: _lyrics.retry,
                child: const Text('歌词暂不可用，轻点重试'),
              ),
            );
          }
          if (doc == null) {
            return Center(
              child: Text('暂无歌词', style: theme.textTheme.bodySmall),
            );
          }
          if (!doc.synchronized) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Column(
                children: [
                  Text('未同步歌词', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 4),
                  SelectableText(
                    doc.plainText,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            );
          }
          final rowHeight = math.max(1.0, (constraints.maxHeight - 12) / 3);
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final font = math.min(
            20.0,
            math.max(1.0, (rowHeight - 2) / (scale * 1.1)),
          );
          final indices = [
            for (
              var i = math.max(_from < 0 ? -1 : 0, _from - 1);
              i <=
                  math.min(
                    _to == doc.cues.length
                        ? doc.cues.length
                        : doc.cues.length - 1,
                    _to + 1,
                  );
              i++
            )
              i,
          ];
          String textAt(int i) => i < 0
              ? '前奏'
              : i >= doc.cues.length
              ? '播放结束'
              : doc.cues[i].text.isEmpty
              ? '间奏'
              : doc.cues[i].text;
          return Semantics(
            label: textAt(_to),
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Flow(
                  delegate: _LyricFlow(
                    animation: _animation,
                    indices: indices,
                    from: _from,
                    to: _to,
                    rowHeight: rowHeight,
                  ),
                  children: [
                    for (final i in indices)
                      Center(
                        key: ValueKey(i),
                        child: i == _to && i >= 0 && i < doc.cues.length
                            ? ScrollingTrackText(
                                text: textAt(i),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: font,
                                  height: 1.1,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary,
                                ),
                              )
                            : Text(
                                textAt(i),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: font * .9,
                                  height: 1.1,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _LyricFlow extends FlowDelegate {
  _LyricFlow({
    required this.animation,
    required this.indices,
    required this.from,
    required this.to,
    required this.rowHeight,
  }) : super(repaint: animation);
  final Animation<double> animation;
  final List<int> indices;
  final int from, to;
  final double rowHeight;
  @override
  BoxConstraints getConstraintsForChild(
    int index,
    BoxConstraints constraints,
  ) => BoxConstraints.tightFor(width: constraints.maxWidth, height: rowHeight);
  @override
  void paintChildren(FlowPaintingContext context) {
    final fraction = Curves.easeOutCubic.transform(animation.value);
    final center = from + (to - from) * fraction;
    for (var child = 0; child < indices.length; child++) {
      final relative = indices[child] - center;
      final distance = relative.abs();
      if (distance > 1.8) continue;
      final opacity = distance <= 1
          ? 1 - distance * (relative < 0 ? .7 : .5)
          : (relative < 0 ? .3 : .5) * (1 - (distance - 1) / .8);
      final transform = Matrix4.translationValues(
        0,
        context.size.height / 2 - rowHeight / 2 + relative * rowHeight,
        0,
      );
      context.paintChild(
        child,
        transform: transform,
        opacity: opacity.clamp(0.0, 1.0),
      );
    }
  }

  @override
  bool shouldRelayout(_LyricFlow oldDelegate) =>
      oldDelegate.rowHeight != rowHeight ||
      oldDelegate.indices.length != indices.length;
  @override
  bool shouldRepaint(_LyricFlow oldDelegate) =>
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.rowHeight != rowHeight ||
      !listEquals(oldDelegate.indices, indices) ||
      oldDelegate.animation != animation;
}
