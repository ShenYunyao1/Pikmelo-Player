import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/playback/ui/scrolling_track_text.dart';

class _PaintCounter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  testWidgets(
    'marquee pauses then moves at a constant rate and wraps without layout changes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              child: ScrollingTrackText(
                text: 'This is a very long music title that must scroll',
                style: TextStyle(fontSize: 20),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final line = find.byType(ScrollingTrackText);
      final first = find
          .descendant(of: line, matching: find.byType(Text))
          .first;
      double offset() =>
          tester.getTopLeft(first).dx - tester.getTopLeft(line).dx;
      final bounds = tester.getRect(line);
      final distance = tester.getSize(first).width + 32;
      final cycle = (distance / 28 * 1000).round() + 1000;
      await tester.pump(const Duration(milliseconds: 1000));
      expect(offset(), closeTo(0, 0.1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(offset(), closeTo(-7, 0.1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(offset(), closeTo(-14, 0.1));
      await tester.pump(Duration(milliseconds: cycle - 1500));
      expect(offset(), closeTo(0, 0.1));
      expect(tester.getRect(line), bounds);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final countBuilds in [true, false]) {
    testWidgets(
      countBuilds
          ? 'scroll frames reuse the shaped text widgets'
          : 'scroll frames leave neighboring content unpainted',
      (tester) async {
        final text = List.filled(20, '很长的标题 Long title ').join();
        final counter = _PaintCounter();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 240,
                height: 180,
                child: Column(
                  children: [
                    CustomPaint(size: const Size(100, 100), painter: counter),
                    ScrollingTrackText(
                      text: text,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        counter.paints = 0;
        var builds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is Text && (element.widget as Text).data == text) {
            builds++;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        if (countBuilds) {
          expect(builds, 0);
        } else {
          expect(counter.paints, 0);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
