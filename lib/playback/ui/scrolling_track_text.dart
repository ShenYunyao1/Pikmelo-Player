import 'package:flutter/material.dart';

/// A fixed-height metadata line that scrolls only when its text overflows.
class ScrollingTrackText extends StatefulWidget {
  const ScrollingTrackText({
    super.key,
    required this.text,
    required this.style,
  });
  final String text;
  final TextStyle style;

  @override
  State<ScrollingTrackText> createState() => _ScrollingTrackTextState();
}

class _ScrollingTrackTextState extends State<ScrollingTrackText>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this);
  Object? _measurement;

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final text = widget.text.replaceAll(RegExp(r'[\r\n\u2028\u2029]+'), ' ');
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final width = painter.width;
      final height = painter.height;
      painter.dispose();
      final scrolling =
          width > constraints.maxWidth &&
          !MediaQuery.disableAnimationsOf(context);
      final distance = width + 32;
      final travel = (distance / 28 * 1000).round();
      final measurement = (
        text,
        style,
        scaler,
        direction,
        constraints.maxWidth,
        scrolling,
      );
      if (_measurement != measurement) {
        _measurement = measurement;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _measurement != measurement) return;
          _animation.stop();
          _animation.value = 0;
          if (scrolling) {
            _animation.duration = Duration(milliseconds: travel + 1000);
            _animation.repeat();
          }
        });
      }
      final line = Text(
        text,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
      return Semantics(
        label: text,
        child: ExcludeSemantics(
          child: SizedBox(
            height: height,
            child: scrolling
                ? ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.centerStart,
                      maxWidth: double.infinity,
                      child: AnimatedBuilder(
                        animation: _animation,
                        builder: (context, _) {
                          final pause = 1000 / (travel + 1000);
                          final progress =
                              ((_animation.value - pause) / (1 - pause)).clamp(
                                0.0,
                                1.0,
                              );
                          return Transform.translate(
                            offset: Offset(
                              (direction == TextDirection.ltr ? -1 : 1) *
                                  distance *
                                  progress,
                              0,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              textDirection: direction,
                              children: [
                                Text(
                                  text,
                                  style: style,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                                const SizedBox(width: 32),
                                Text(
                                  text,
                                  style: style,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  )
                : line,
          ),
        ),
      );
    },
  );
}
