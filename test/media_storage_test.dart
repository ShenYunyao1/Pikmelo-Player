import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/infrastructure/storage/media_files.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/settings/media_storage_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalLibraryStore store;
  late MediaStorageController storage;
  var cellular = true;
  final server = Uri.parse('https://example.com');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pikmelo-storage-');
    store = await LocalLibraryStore.open(
      databasePath: '${root.path}/library.sqlite',
    );
    cellular = true;
    storage = MediaStorageController(
      store,
      networkReader: () async => {'connected': true, 'cellular': cellular},
    );
    await storage.ready;
  });
  tearDown(() async {
    await storage.shutdown();
    store.close();
    await root.delete(recursive: true);
  });

  Future<File> media(String id, {int size = 10, bool pinned = true}) async {
    final file = File('${root.path}/$id.media');
    await file.writeAsBytes(List.filled(10, 7));
    if (size != 10) {
      final handle = await file.open(mode: FileMode.append);
      await handle.truncate(size);
      await handle.close();
    }
    store.retainMedia(server, id, pinned: pinned);
    store.applySyncPages(server, [
      PikmeloSyncPage(
        changedTracks: [
          {'id': id, 'title': id, 'size': size},
        ],
        playlists: [],
        deletedTracks: [],
        deletedPlaylists: [],
        cursor: id,
        hasMore: false,
        fullSnapshot: false,
        reset: false,
        revision: 1,
      ),
    ]);
    store.saveOfflineMedia(
      serverUri: server,
      expectedGeneration: store.generationFor(server),
      trackId: id,
      track: {'id': id, 'title': id, 'size': size},
      file: file,
      etag: null,
    );
    return file;
  }

  test('all three cellular policies and Wi-Fi are enforced', () async {
    expect(storage.allows(DownloadPurpose.playback), isTrue);
    expect(storage.allows(DownloadPurpose.manual), isFalse);
    expect(storage.allows(DownloadPurpose.prefetch), isFalse);
    storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
    for (final purpose in DownloadPurpose.values) {
      expect(storage.allows(purpose), isFalse);
    }
    storage.setMobilePolicy(MobileDownloadPolicy.allow);
    for (final purpose in DownloadPurpose.values) {
      expect(storage.allows(purpose), isTrue);
    }
    cellular = false;
    storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
    await storage.refreshNetwork();
    expect(storage.allows(DownloadPurpose.manual), isTrue);
  });

  test(
    'migration verifies copies, changes records and removes original files',
    () async {
      final old = await media('migrate');
      final bytes = await old.readAsBytes();
      final target = '${root.path}/new-media';
      await storage.changeDirectory(target, migrate: true);
      final path = store.offlineTracks().single['file_path'] as String;
      expect(path, startsWith(target));
      expect(await File(path).readAsBytes(), bytes);
      expect(await old.exists(), isFalse);
      expect(storage.migrationPending, isFalse);
      expect(store.pendingFileDeletions(), isEmpty);
      expect(store.mediaPinned(server, 'migrate'), isTrue);
    },
  );

  test(
    'future-only directory change preserves existing files and settings reopen',
    () async {
      final old = await media('keep');
      final target = '${root.path}/future';
      await storage.changeDirectory(target, migrate: false);
      storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
      storage.setCacheLimit(256 * 1024 * 1024);
      await storage.shutdown();
      store.close();
      store = await LocalLibraryStore.open(
        databasePath: '${root.path}/library.sqlite',
      );
      storage = MediaStorageController(
        store,
        networkReader: () async => {'connected': true, 'cellular': true},
      );
      await storage.ready;
      expect(storage.directory, target);
      expect(storage.mobilePolicy, MobileDownloadPolicy.prohibit);
      expect(storage.cacheLimit, 256 * 1024 * 1024);
      expect(store.offlineTracks().single['file_path'], old.path);
      expect(await old.exists(), isTrue);
    },
  );

  test(
    'failed migration journal resumes after a directory is repaired',
    () async {
      final old = await media('retry');
      final obstruction = File('${root.path}/destination');
      await obstruction.writeAsString('occupied');
      await expectLater(
        storage.changeDirectory(obstruction.path, migrate: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(storage.migrationPending, isTrue);
      expect(await old.exists(), isTrue);
      expect(
        jsonDecode(store.setting('media_migration')!)['files'],
        hasLength(1),
      );
      await obstruction.delete();
      await storage.shutdown();
      storage = MediaStorageController(
        store,
        networkReader: () async => {'connected': true, 'cellular': false},
      );
      await storage.ready;
      await storage.changeDirectory(null, migrate: true);
      expect(storage.directory, obstruction.path);
      expect(await old.exists(), isFalse);
      expect(storage.migrationPending, isFalse);
    },
  );

  test(
    'LRU cleanup preserves pinned downloads and protected playback',
    () async {
      const size = 40 * 1024 * 1024;
      final manual = await media('manual', size: size);
      final evicted = await media('cache-old', size: size, pinned: false);
      final current = await media('cache-current', size: size, pinned: false);
      storage.setCacheLimit(64 * 1024 * 1024);
      final removed = await storage.trimCache({current.path});
      expect(removed.single.id, 'cache-old');
      expect(await evicted.exists(), isFalse);
      expect(await manual.exists(), isTrue);
      expect(await current.exists(), isTrue);
      expect(storage.cacheBytes, size);
    },
  );

  test('document URI stat refresh detects revoked or missing files', () async {
    const path = 'content://documents/tree/music/document/song';
    var exists = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MediaFiles.android, (call) async {
      expect(call.method, 'stat');
      return {path: exists ? 10 : -1};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(MediaFiles.android, null),
    );
    expect(await store.files.validate(path, 10), isTrue);
    exists = false;
    expect(await store.files.validate(path, 10), isFalse);
    expect(store.files.exists(path), isFalse);
  });

  test(
    'resumed downloads publish into the newly selected local directory',
    () async {
      final source = File('${root.path}/old-staging.media');
      await source.writeAsBytes([1, 2, 3, 4]);
      final target = '${root.path}/new-publish';
      await storage.changeDirectory(target, migrate: false);
      final path = await storage.publish(source);
      expect(path, startsWith(target));
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      expect(await source.exists(), isTrue);
    },
  );
}
