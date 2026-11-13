import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/playback/models/playback_item.dart';
import 'package:pikmelo_player/playback/models/playback_state.dart';
import 'package:pikmelo_player/playback/playback_controller.dart';
import 'package:pikmelo_player/playback/playback_session.dart';

void main() {
  late LocalLibraryStore store;
  late Directory directory;
  final uri = Uri.parse('https://example.com');
  final tracks = [
    for (final id in ['one', 'two']) {'id': id, 'title': id, 'size': 5},
  ];
  PlaybackController player() => PlaybackController(
    createEngine: () => throw StateError('Restoration must not open audio'),
    isAvailable: (_) => true,
  );
  List<PlaybackItem> items() => [
    for (final track in tracks)
      PlaybackItem(
        serverUri: uri,
        track: Track.fromJson(track),
        path: '/obsolete-path',
      ),
  ];
  void seed() => store.applySyncPages(uri, [
    PikmeloSyncPage(
      changedTracks: tracks,
      playlists: [],
      deletedTracks: [],
      deletedPlaylists: [],
      cursor: 'base',
      hasMore: false,
      fullSnapshot: true,
      reset: false,
      revision: 1,
    ),
  ]);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pikmelo-session-');
    store = await LocalLibraryStore.open(
      databasePath: '${directory.path}/library.sqlite',
    );
    seed();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'legacy mode initializes default and snapshots retain their own mode',
    () async {
      store.saveSetting(
        'playback_preferences',
        '{"mode":"repeatAll","volume":50}',
      );
      final first = player();
      final session = PlaybackSession(
        store: store,
        player: first,
        scope: 'key',
        serverUri: uri,
      );
      expect(first.defaultMode, PlaybackMode.repeatAll);
      first.append(items().first);
      first.setMode(PlaybackMode.shuffle);
      first.setDefaultMode(PlaybackMode.repeatOne);
      expect(first.mode, PlaybackMode.shuffle);
      session.dispose();
      await first.shutdown();
      final next = player();
      final restored = PlaybackSession(
        store: store,
        player: next,
        scope: 'key',
        serverUri: uri,
      );
      expect(next.mode, PlaybackMode.shuffle);
      expect(next.defaultMode, PlaybackMode.repeatOne);
      expect(next.queue, hasLength(1));
      restored.dispose();
      await next.shutdown();
    },
  );

  test('malformed preferences do not block startup', () async {
    store.saveSetting('playback_preferences', '{broken');
    final current = player();
    final session = PlaybackSession(
      store: store,
      player: current,
      scope: 'key',
      serverUri: uri,
    );
    expect(current.queue, isEmpty);
    expect(current.volume, 100);
    session.dispose();
    await current.shutdown();
  });

  test(
    'preferences persist without credentials and clear removes the saved queue',
    () async {
      final first = player();
      final preferences = PlaybackSession(
        store: store,
        player: first,
        scope: 'preferences',
        serverUri: uri,
        restoreQueue: false,
      );
      first.setDefaultMode(PlaybackMode.repeatOne);
      await first.setVolume(25);
      preferences.dispose();
      await first.shutdown();
      final second = player();
      final session = PlaybackSession(
        store: store,
        player: second,
        scope: 'key',
        serverUri: uri,
      );
      expect(second.mode, PlaybackMode.repeatOne);
      expect(second.volume, 25);
      second.restoreQueue(items());
      await second.clear();
      session.dispose();
      await second.shutdown();
      final third = player();
      final restored = PlaybackSession(
        store: store,
        player: third,
        scope: 'key',
        serverUri: uri,
      );
      expect(third.queue, isEmpty);
      restored.dispose();
      await third.shutdown();
    },
  );

  test('reopened database restores queue and position paused using fresh file paths', () async {
    final first = player();
    final session = PlaybackSession(
      store: store,
      player: first,
      scope: 'server-key',
      serverUri: uri,
    );
    first.restoreQueue(
      items(),
      index: 1,
      position: const Duration(seconds: 4),
      duration: const Duration(seconds: 10),
      mode: PlaybackMode.repeatAll,
      volume: 37,
    );
    session.dispose();
    await first.shutdown();
    store.close();
    store = await LocalLibraryStore.open(
      databasePath: '${directory.path}/library.sqlite',
    );
    final audio = File('${directory.path}/migrated.media');
    await audio.writeAsBytes(List.filled(5, 0));
    store.saveOfflineMedia(
      serverUri: uri,
      expectedGeneration: store.generationFor(uri),
      trackId: 'two',
      track: tracks.last,
      file: audio,
    );
    final second = player();
    final restored = PlaybackSession(
      store: store,
      player: second,
      scope: 'server-key',
      serverUri: uri,
    );
    expect(second.queue, hasLength(2));
    expect(second.current?.track.id, 'two');
    expect(second.current?.path, audio.path);
    expect(second.state.position, const Duration(seconds: 4));
    expect(second.mode, PlaybackMode.repeatAll);
    expect(second.volume, 37);
    expect(second.stopped, isTrue);
    expect(second.playRequested, isFalse);
    restored.dispose();
    await second.shutdown();
  });

  test(
    'scope isolation and disabled queue restore preserve volume preferences',
    () async {
      final first = player();
      final session = PlaybackSession(
        store: store,
        player: first,
        scope: 'first-key',
        serverUri: uri,
      );
      first.restoreQueue(items(), volume: 42, mode: PlaybackMode.shuffle);
      session.dispose();
      await first.shutdown();
      final second = player();
      final other = PlaybackSession(
        store: store,
        player: second,
        scope: 'second-key',
        serverUri: uri,
      );
      expect(second.queue, isEmpty);
      expect(second.volume, 42);
      expect(second.mode, PlaybackMode.shuffle);
      other.setEnabled(false);
      other.dispose();
      await second.shutdown();
      final third = player();
      final disabled = PlaybackSession(
        store: store,
        player: third,
        scope: 'first-key',
        serverUri: uri,
      );
      expect(third.queue, isEmpty);
      expect(third.volume, 42);
      disabled.dispose();
      await third.shutdown();
    },
  );

  test('revoked tracks are filtered and an unavailable selection resets the position', () async {
    final first = player();
    final session = PlaybackSession(
      store: store,
      player: first,
      scope: 'key',
      serverUri: uri,
    );
    first.restoreQueue(items(), index: 1, position: const Duration(seconds: 4));
    session.dispose();
    await first.shutdown();
    store.applySyncPages(uri, [
      PikmeloSyncPage(
        changedTracks: [],
        playlists: [],
        deletedTracks: ['two'],
        deletedPlaylists: [],
        cursor: 'new',
        hasMore: false,
        fullSnapshot: false,
        reset: false,
        revision: 2,
      ),
    ]);
    final second = player();
    final restored = PlaybackSession(
      store: store,
      player: second,
      scope: 'key',
      serverUri: uri,
    );
    expect(second.queue.single.track.id, 'one');
    expect(second.state.position, Duration.zero);
    restored.dispose();
    await second.shutdown();
  });
}
