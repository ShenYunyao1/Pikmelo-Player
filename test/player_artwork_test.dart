import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/ui/player_artwork.dart';

void main() {
  testWidgets(
    'failed artwork remains reusable and refreshes for network and metadata changes',
    (tester) async {
      final item = PlaybackItem(
        serverUri: Uri.parse('https://example.com'),
        path: '/one.media',
        track: Track.fromJson({'id': 'one', 'title': 'One'}),
      );
      var requests = 0;
      Future<Uint8List?> load(PlaybackItem item) async {
        requests++;
        throw StateError('temporary image failure');
      }

      Widget page(PlaybackItem item, int revision) => MaterialApp(
        home: Center(
          child: PlayerArtwork(
            item: item,
            size: 48,
            loadArtwork: load,
            revision: revision,
          ),
        ),
      );
      await tester.pumpWidget(page(item, 0));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pumpWidget(page(item, 0));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pumpWidget(page(item, 1));
      await tester.pumpAndSettle();
      expect(requests, 2);
      final changed = PlaybackItem(
        serverUri: item.serverUri,
        path: item.path,
        track: Track.fromJson({'id': 'one', 'title': 'New title'}),
      );
      await tester.pumpWidget(page(changed, 1));
      await tester.pumpAndSettle();
      expect(requests, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
