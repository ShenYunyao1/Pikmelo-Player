import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pikmelo_player/downloads/download_manager.dart';
import 'package:pikmelo_player/downloads/models/download_task.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/settings/media_storage_controller.dart';

void main() {
  late HttpServer server;
  late Uri uri;
  late LocalLibraryStore store;
  late Directory directory;
  late DownloadManager manager;
  final track = Track.fromJson({'id': 'track-1', 'title': 'Song', 'size': 10});

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}');
    directory = await Directory.systemTemp.createTemp('pikmelo-downloads-');
    store = await LocalLibraryStore.open(
      databasePath: '${directory.path}/library.sqlite',
    );
    store.applySyncPages(uri, [
      PikmeloSyncPage(
        changedTracks: [track.toJson()],
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
    manager = DownloadManager(
      store: store,
      serverUri: uri,
      cacheDirectory: () async => directory,
      createClient: () => PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
    );
  });

  tearDown(() async {
    await manager.shutdown();
    await server.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  Future<MediaStorageController> usePolicy({bool mobile = true}) async {
    await manager.shutdown();
    final storage = MediaStorageController(
      store,
      networkReader: () async => {'connected': true, 'cellular': mobile},
    );
    await storage.ready;
    await storage.changeDirectory(directory.path, migrate: false);
    manager = DownloadManager(
      store: store,
      serverUri: uri,
      storage: storage,
      cacheDirectory: () async => directory,
      createClient: () => PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
    );
    addTearDown(() async {
      await manager.shutdown();
      await storage.shutdown();
    });
    return storage;
  }

  test('prohibit blocks every download purpose and permits existing local playback', () async {
    final storage = await usePolicy();
    storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add(List.filled(10, 1));
      await request.response.close();
    });
    for (final purpose in DownloadPurpose.values) {
      await expectLater(
        manager.ensureReady(track, purpose: purpose),
        throwsStateError,
      );
    }
    expect(requests, 0);
    storage.setMobilePolicy(MobileDownloadPolicy.allow);
    final path = await manager.ensureReady(
      track,
      purpose: DownloadPurpose.playback,
    );
    storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
    expect(
      await manager.ensureReady(track, purpose: DownloadPurpose.playback),
      path,
    );
    expect(requests, 1);
  });

  test('playback-only policy blocks manual and prefetch but downloads the selected song', () async {
    await usePolicy();
    server.listen((request) async {
      request.response.add(List.filled(10, 3));
      await request.response.close();
    });
    await expectLater(
      manager.ensureReady(track, purpose: DownloadPurpose.prefetch),
      throwsStateError,
    );
    await expectLater(
      manager.ensureReady(track, purpose: DownloadPurpose.manual),
      throwsStateError,
    );
    final path = await manager.ensureReady(
      track,
      purpose: DownloadPurpose.playback,
    );
    expect(await File(path).length(), 10);
  });

  test('cancel preparation interrupts the waiter and keeps playback cache unpinned', () async {
    final release = Completer<void>();
    server.listen((request) async {
      try {
        request.response.bufferOutput = false;
        request.response.contentLength = 10;
        request.response.add([1, 2]);
        await request.response.flush();
        await release.future;
        await request.response.close();
      } on IOException {
        /* Client cancellation is expected. */
      }
    });
    final preparing = manager.ensureReady(
      track,
      purpose: DownloadPurpose.playback,
    );
    final stopped = expectLater(preparing, throwsStateError);
    await _until(
      () => manager.tasks.isNotEmpty && manager.tasks.single.received == 2,
    );
    manager.cancelPreparation();
    await stopped;
    expect(store.mediaPinned(uri, track.id), isFalse);
    expect(manager.tasks.single.status, DownloadStatus.paused);
    release.complete();
  });

  test(
    'manual download pins existing playback cache without another request',
    () async {
      var calls = 0;
      server.listen((request) async {
        calls++;
        request.response.add(List.filled(10, 4));
        await request.response.close();
      });
      await manager.ensureReady(track, purpose: DownloadPurpose.playback);
      expect(store.mediaPinned(uri, track.id), isFalse);
      manager.enqueue(track);
      expect(store.mediaPinned(uri, track.id), isTrue);
      expect(calls, 1);
    },
  );

  test(
    'duplicate requests share queue work, complete and can be deleted',
    () async {
      var calls = 0;
      server.listen((request) async {
        calls++;
        request.response.headers.set('ETag', '"v1"');
        request.response.add(List.generate(10, (index) => index));
        await request.response.close();
      });
      manager.enqueue(track);
      manager.enqueue(track);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
      expect(calls, 1);
      expect(store.offlineTracks(serverUri: uri), hasLength(1));
      await manager.remove(track.id);
      expect(manager.tasks, isEmpty);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
    },
  );

  test(
    'network changes pause an active transfer under the prohibit policy',
    () async {
      await manager.shutdown();
      var cellular = false;
      final storage = MediaStorageController(
        store,
        networkReader: () async => {'connected': true, 'cellular': cellular},
      );
      await storage.ready;
      await storage.changeDirectory(directory.path, migrate: false);
      storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
      manager = DownloadManager(
        store: store,
        serverUri: uri,
        storage: storage,
        createClient: () =>
            PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
      );
      addTearDown(() async {
        await manager.shutdown();
        await storage.shutdown();
      });
      final release = Completer<void>();
      server.listen((request) async {
        try {
          request.response.bufferOutput = false;
          request.response.contentLength = 10;
          request.response.add([1, 2]);
          await request.response.flush();
          await release.future;
          await request.response.close();
        } on IOException {
          /* Network policy closes the incomplete transfer. */
        }
      });
      manager.enqueue(track);
      await _until(() => manager.tasks.single.received == 2);
      cellular = true;
      await storage.refreshNetwork();
      await _until(() => manager.tasks.single.status == DownloadStatus.paused);
      expect(store.offlineTracks(), isEmpty);
      release.complete();
    },
  );

  test(
    'selected playback preempts a manual transfer and resumes background work',
    () async {
      final selected = Track.fromJson({
        'id': 'track-2',
        'title': 'Selected',
        'size': 10,
      });
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [track.toJson(), selected.toJson()],
          playlists: [],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'priority',
          hasMore: false,
          fullSnapshot: false,
          reset: false,
          revision: 2,
        ),
      ]);
      final release = Completer<void>();
      final requested = <String>[];
      server.listen((request) async {
        requested.add(request.uri.path);
        try {
          if (requested.length == 1) {
            request.response.bufferOutput = false;
            request.response.contentLength = 10;
            request.response.add([1, 2]);
            await request.response.flush();
            await release.future;
          } else {
            request.response.add(List.filled(10, 1));
          }
          await request.response.close();
        } on IOException {
          /* Foreground playback preempts this transfer. */
        }
      });
      manager.enqueue(track);
      await _until(() => manager.tasks.single.received == 2);
      final path = await manager.ensureReady(
        selected,
        purpose: DownloadPurpose.playback,
      );
      expect(await File(path).length(), 10);
      expect(requested[1], contains(selected.id));
      release.complete();
      await _until(
        () => manager.tasks.every(
          (task) => task.status == DownloadStatus.completed,
        ),
      );
      expect(store.mediaPinned(uri, track.id), isTrue);
      expect(store.mediaPinned(uri, selected.id), isFalse);
    },
  );

  test(
    'pause waits for partial file and resume sends Range and If-Range',
    () async {
      final release = Completer<void>();
      server.listen((request) async {
        try {
          request.response.headers.set('ETag', '"v1"');
          if (request.headers.value('Range') == null) {
            request.response.bufferOutput = false;
            request.response.contentLength = 10;
            request.response.add([0, 1, 2, 3, 4]);
            await request.response.flush();
            await release.future;
          } else {
            expect(request.headers.value('Range'), 'bytes=5-');
            expect(request.headers.value('If-Range'), '"v1"');
            request.response.statusCode = 206;
            request.response.headers.set('Content-Range', 'bytes 5-9/10');
            request.response.add([5, 6, 7, 8, 9]);
          }
          await request.response.close();
        } on IOException {
          // Pausing closes the intentionally incomplete server response.
        }
      });
      manager.enqueue(track);
      await _until(() => manager.tasks.single.received == 5);
      await manager.pause(track.id);
      expect(manager.tasks.single.status, DownloadStatus.paused);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
      final partial = store.downloadTask(uri, track.id)!['file_path'] as String;
      expect(await File(partial).length(), 5);
      release.complete();
      manager.resume(track.id);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
    },
  );

  test(
    'restart restores interrupted tasks as paused and detects missing media',
    () async {
      store.saveDownloadQueue(uri, track.id, 'downloading', 5, null);
      await manager.shutdown();
      store.close();
      store = await LocalLibraryStore.open(
        databasePath: '${directory.path}/library.sqlite',
      );
      manager = DownloadManager(
        store: store,
        serverUri: uri,
        cacheDirectory: () async => directory,
        createClient: () =>
            PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
      );
      expect(manager.tasks.single.status, DownloadStatus.paused);
      server.listen((request) async {
        request.response.add(List.filled(10, 1));
        await request.response.close();
      });
      manager.resume(track.id);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
      final path =
          store.offlineTracks(serverUri: uri).single['file_path'] as String;
      await File(path).delete();
      await manager.shutdown();
      manager = DownloadManager(
        store: store,
        serverUri: uri,
        cacheDirectory: () async => directory,
        createClient: () =>
            PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
      );
      expect(manager.tasks.single.status, DownloadStatus.failed);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
    },
  );

  test('cancel stops an active writer and removes its partial task', () async {
    final release = Completer<void>();
    server.listen((request) async {
      try {
        request.response.bufferOutput = false;
        request.response.contentLength = 10;
        request.response.add([1, 2, 3, 4, 5]);
        await request.response.flush();
        await release.future;
        await request.response.close();
      } on IOException {
        // Cancelling closes the intentionally incomplete server response.
      }
    });
    manager.enqueue(track);
    await _until(() => manager.tasks.single.received == 5);
    final partial = store.downloadTask(uri, track.id)!['file_path'] as String;
    await manager.cancel(track.id);
    release.complete();
    expect(manager.tasks, isEmpty);
    expect(store.downloadTask(uri, track.id), isNull);
    expect(await File(partial).exists(), isFalse);
    expect(store.offlineTracks(serverUri: uri), isEmpty);
  });

  test(
    'failed storage stays retryable and does not publish incomplete media',
    () async {
      server.listen((request) async {
        request.response.add(List.filled(10, 1));
        await request.response.close();
      });
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('file');
      var failStorage = true;
      await manager.shutdown();
      manager = DownloadManager(
        store: store,
        serverUri: uri,
        cacheDirectory: () async =>
            failStorage ? Directory('${blocked.path}/media') : directory,
        createClient: () =>
            PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
      );
      manager.enqueue(track);
      await _until(() => manager.tasks.single.status == DownloadStatus.failed);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
      expect(manager.tasks.single.error, contains('存储空间'));
      failStorage = false;
      manager.resume(track.id);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
    },
  );

  test(
    'content changes invalidate a previously completed local file',
    () async {
      server.listen((request) async {
        request.response.add(List.filled(10, 1));
        await request.response.close();
      });
      manager.enqueue(track);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
      await manager.shutdown();
      final paths = store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [
            {...track.toJson(), 'content_hash': 'changed'},
          ],
          playlists: [],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'next',
          hasMore: false,
          fullSnapshot: false,
          reset: false,
          revision: 2,
        ),
      ]);
      expect(paths, hasLength(1));
      expect(store.pendingFileDeletions(), paths);
      expect(store.offlineTracks(serverUri: uri), isEmpty);
    },
  );

  test(
    'serial queue advances after a failed request and permits retry',
    () async {
      final second = Track.fromJson({
        'id': 'track-2',
        'title': 'Second',
        'size': 10,
      });
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [second.toJson()],
          playlists: [],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'two',
          hasMore: false,
          fullSnapshot: false,
          reset: false,
          revision: 2,
        ),
      ]);
      final order = <String>[];
      var failFirst = true;
      server.listen((request) async {
        final id = request.uri.pathSegments.last;
        order.add(id);
        if (id == track.id && failFirst) {
          request.response.statusCode = 503;
        } else {
          request.response.add(List.filled(10, 1));
        }
        await request.response.close();
      });
      manager.enqueue(track);
      manager.enqueue(second);
      await _until(() => manager.tasks.last.status == DownloadStatus.completed);
      expect(order, ['track-1', 'track-2']);
      expect(manager.tasks.first.status, DownloadStatus.failed);
      failFirst = false;
      manager.resume(track.id);
      await _until(
        () => manager.tasks.every(
          (task) => task.status == DownloadStatus.completed,
        ),
      );
    },
  );
  test(
    'permission generation changes isolate partial files from new downloads',
    () async {
      final old = File('${directory.path}/track-1.part');
      await old.writeAsBytes([1, 2, 3, 4, 5]);
      store.savePartialEtag(
        uri,
        store.generationFor(uri),
        track.id,
        '"old"',
        old.path,
      );
      await manager.shutdown();
      final legacy = sqlite3.open('${directory.path}/library.sqlite');
      legacy.execute('UPDATE download_tasks SET generation = NULL');
      legacy.close();
      store.invalidateServer(uri);
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [track.toJson()],
          playlists: [],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'new',
          hasMore: false,
          fullSnapshot: true,
          reset: false,
          revision: 2,
        ),
      ]);
      server.listen((request) async {
        expect(request.headers.value('Range'), isNull);
        request.response.add(List.filled(10, 2));
        await request.response.close();
      });
      manager = DownloadManager(
        store: store,
        serverUri: uri,
        cacheDirectory: () async => directory,
        createClient: () =>
            PikmeloApiClient(serverUri: uri, apiKey: 'test-key'),
      );
      manager.resume(track.id);
      await _until(
        () => manager.tasks.single.status == DownloadStatus.completed,
      );
      expect(store.pendingFileDeletions(), contains(old.path));
      final completed =
          store.offlineTracks(serverUri: uri).single['file_path'] as String;
      expect(File(completed).parent.path, isNot(old.parent.path));
    },
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Download did not reach its expected state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
