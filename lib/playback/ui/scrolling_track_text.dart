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
          child: RepaintBoundary(
            child: SizedBox(
              height: height,
              child: scrolling
                  ? Flow(
                      delegate: _ScrollingTextFlow(
                        animation: _animation,
                        distance: distance,
                        direction: direction,
                        pause: 1000 / (travel + 1000),
                      ),
                      children: [
                        RepaintBoundary(
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
                        ),
                      ],
                    )
                  : line,
            ),
          ),
        ),
      );
    },
  );
}

class _ScrollingTextFlow extends FlowDelegate {
  _ScrollingTextFlow({
    required this.animation,
    required this.distance,
    required this.direction,
    required this.pause,
  }) : super(repaint: animation);
  final Animation<double> animation;
  final double distance;
  final TextDirection direction;
  final double pause;

  @override
  BoxConstraints getConstraintsForChild(
    int index,
    BoxConstraints constraints,
  ) => BoxConstraints.tightFor(
    width: distance * 2 - 32,
    height: constraints.maxHeight,
  );

  @override
  void paintChildren(FlowPaintingContext context) {
    final progress = ((animation.value - pause) / (1 - pause)).clamp(0.0, 1.0);
    final offset = direction == TextDirection.ltr
        ? -distance * progress
        : context.size.width -
              context.getChildSize(0)!.width +
              distance * progress;
    context.paintChild(0, transform: Matrix4.translationValues(offset, 0, 0));
  }

  @override
  bool shouldRepaint(_ScrollingTextFlow oldDelegate) =>
      oldDelegate.distance != distance ||
      oldDelegate.direction != direction ||
      oldDelegate.pause != pause ||
      oldDelegate.animation != animation;
  @override
  bool shouldRelayout(_ScrollingTextFlow oldDelegate) =>
      oldDelegate.distance != distance;
}
