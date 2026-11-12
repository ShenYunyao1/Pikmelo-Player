import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';
import 'package:pikmelo_player/playback/ui/queue_page.dart';

void main() {
  testWidgets('queue menu moves and removes entries in a narrow panel', (
    tester,
  ) async {
    final controller = PlaybackController(
      createEngine: () => throw StateError('Queue edits must not open audio'),
      isAvailable: (_) => true,
    );
    for (var index = 0; index < 2; index++) {
      controller.append(
        PlaybackItem(
          serverUri: Uri.parse('https://example.com'),
          track: Track.fromJson({'id': '$index', 'title': 'Song $index'}),
          path: '',
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: QueueContents(controller: controller),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('队列曲目操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(controller.queue.first.track.id, '1');
    expect(controller.current?.track.id, '0');
    await tester.tap(find.byTooltip('队列曲目操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出队列'));
    await tester.pumpAndSettle();
    expect(controller.queue.single.track.id, '0');
    expect(tester.takeException(), isNull);
    final closing = controller.shutdown();
    await tester.pump();
    await closing;
    controller.dispose();
  });
}
