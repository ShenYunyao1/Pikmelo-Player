import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/downloads/media_download_service.dart';
import 'package:pikmelo_player/sync/sync_service.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';

void main() {
  group('Pikmelo protocol core', () {
    late HttpServer server;
    late Uri serverUri;
    late List<Uri> requests;

    setUp(() async {
      requests = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUri = Uri.parse('http://${server.address.address}:${server.port}');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('sync commits its cursor only after every page completes', () async {
      var nextPage = false;
      server.listen((request) async {
        requests.add(request.uri);
        expect(request.headers.value('X-API-Key'), 'test-key');
        final response = request.response;
        response.headers.contentType = ContentType.json;
        if (!nextPage) {
          expect(request.uri.queryParameters['cursor'], isNull);
          nextPage = true;
          response.write(
            jsonEncode({
              'changed_tracks': [
                {'id': 'track-1', 'title': 'First Song'},
              ],
              'playlists': [],
              'deleted_tracks': [],
              'deleted_playlists': [],
              'cursor': 'page-one',
              'has_more': true,
              'full_snapshot': true,
              'reset': true,
              'revision': 7,
            }),
          );
        } else {
          expect(request.uri.queryParameters['cursor'], 'page-one');
          response.write(
            jsonEncode({
              'changed_tracks': [],
              'playlists': [
                {
                  'id': 'playlist-1',
                  'name': 'Favorites',
                  'track_ids': ['track-1'],
                },
              ],
              'deleted_tracks': [],
              'deleted_playlists': [],
              'cursor': 'final-cursor',
              'has_more': false,
              'full_snapshot': true,
              'reset': false,
              'revision': 7,
            }),
          );
        }
        await response.close();
      });

      final client = PikmeloApiClient(serverUri: serverUri, apiKey: 'test-key');
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(() {
        client.close();
        store.close();
      });

      final result = await SyncService(
        client: client,
        store: store,
        serverUri: serverUri,
      ).synchronize();

      expect(result.pages, 2);
      expect(store.cursorFor(serverUri), 'final-cursor');
      expect(store.playlists(serverUri).single['name'], 'Favorites');
      expect(requests, hasLength(2));
    });

    test(
      'SYNC_RESTART discards the old cursor and retries a fresh snapshot',
      () async {
        var syncRequestCount = 0;
        server.listen((request) async {
          if (request.uri.path.endsWith('/health')) {
            request.response.statusCode = HttpStatus.unauthorized;
            await request.response.close();
            return;
          }
          syncRequestCount++;
          final response = request.response;
          response.headers.contentType = ContentType.json;
          if (request.uri.queryParameters['cursor'] == 'previous-cursor') {
            response.statusCode = HttpStatus.conflict;
            response.headers.set('X-Error-Code', 'SYNC_RESTART');
            response.write(jsonEncode({'error': 'restart snapshot'}));
          } else {
            response.write(
              jsonEncode({
                'changed_tracks': [],
                'playlists': [],
                'deleted_tracks': [],
                'deleted_playlists': [],
                'cursor': 'fresh-cursor',
                'has_more': false,
                'full_snapshot': true,
                'reset': true,
                'revision': 10,
              }),
            );
          }
          await response.close();
        });

        final store = await LocalLibraryStore.open(databasePath: ':memory:');
        store.applySyncPages(serverUri, [
          _syncPage(cursor: 'previous-cursor', revision: 8),
        ]);
        final client = PikmeloApiClient(
          serverUri: serverUri,
          apiKey: 'test-key',
        );
        addTearDown(() {
          client.close();
          store.close();
        });

        final result = await SyncService(
          client: client,
          store: store,
          serverUri: serverUri,
        ).synchronize();

        expect(result.restarted, isTrue);
        expect(syncRequestCount, 2);
        expect(store.cursorFor(serverUri), 'fresh-cursor');
      },
    );

    test('server snapshots remain isolated when switching servers', () async {
      final otherServer = serverUri.replace(path: '/music-prefix');
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);

      store.applySyncPages(serverUri, [
        _syncPage(
          cursor: 'first-server-cursor',
          revision: 1,
          changedTracks: [
            {'id': 'track-1', 'title': 'First server song'},
          ],
          playlists: [
            {
              'id': 'playlist-1',
              'name': 'First server list',
              'track_ids': ['track-1'],
            },
          ],
        ),
      ]);
      store.applySyncPages(otherServer, [
        _syncPage(cursor: 'second-server-cursor', revision: 2, reset: true),
      ]);

      expect(store.cursorFor(serverUri), 'first-server-cursor');
      expect(store.cursorFor(otherServer), 'second-server-cursor');
      expect(store.playlists(serverUri).single['name'], 'First server list');
      expect(store.playlists(otherServer), isEmpty);
    });

    test('reset removes partial tasks outside the new snapshot', () async {
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      const partialPath = 'partial-track.part';
      store.applySyncPages(serverUri, [
        _syncPage(
          cursor: 'track-cursor',
          revision: 1,
          changedTracks: [
            {'id': 'track-old', 'title': 'Old track'},
          ],
        ),
      ]);
      store.savePartialEtag(
        serverUri,
        store.generationFor(serverUri),
        'track-old',
        '"old"',
        partialPath,
      );

      final stalePaths = store.applySyncPages(serverUri, [
        _syncPage(cursor: 'reset-cursor', revision: 3, reset: true),
      ]);

      expect(stalePaths, [partialPath]);
      expect(store.downloadTask(serverUri, 'track-old'), isNull);
    });

    test('partial redownload tasks do not replace completed offline media', () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'pikmelo-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final completeFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}track-1-old.media',
      );
      await completeFile.writeAsString('complete-audio');
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      store.applySyncPages(serverUri, [
        _syncPage(
          cursor: 'track-cursor',
          revision: 1,
          changedTracks: [
            {'id': 'track-1', 'title': 'Song'},
          ],
        ),
      ]);

      store.saveOfflineMedia(
        serverUri: serverUri,
        expectedGeneration: store.generationFor(serverUri),
        trackId: 'track-1',
        track: {'id': 'track-1', 'title': 'Song'},
        file: completeFile,
        etag: '"old"',
      );
      store.savePartialEtag(
        serverUri,
        store.generationFor(serverUri),
        'track-1',
        '"new"',
        '${temporaryDirectory.path}${Platform.pathSeparator}track-1.part',
      );

      final otherServer = serverUri.replace(path: '/another-music-prefix');
      expect(store.offlineTracks(serverUri: serverUri).single['etag'], '"old"');
      expect(store.downloadTask(serverUri, 'track-1')?['etag'], '"new"');
      expect(store.offlineTracks(serverUri: otherServer), isEmpty);
    });

    test(
      'reset requires a media-scope check before restoring cached playback',
      () async {
        final temporaryDirectory = await Directory.systemTemp.createTemp(
          'pikmelo-test-',
        );
        addTearDown(() => temporaryDirectory.delete(recursive: true));
        final completeFile = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}track-1.media',
        );
        await completeFile.writeAsString('audio-data');
        final secondFile = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}track-2.media',
        );
        await secondFile.writeAsString('second-audio');
        final store = await LocalLibraryStore.open(databasePath: ':memory:');
        addTearDown(store.close);
        final track = {'id': 'track-1', 'title': 'Song', 'size': 10};
        final secondTrack = {
          'id': 'track-2',
          'title': 'Second Song',
          'size': 12,
        };

        store.applySyncPages(serverUri, [
          _syncPage(
            cursor: 'initial',
            revision: 1,
            changedTracks: [track, secondTrack],
          ),
        ]);
        store.saveOfflineMedia(
          serverUri: serverUri,
          expectedGeneration: store.generationFor(serverUri),
          trackId: 'track-1',
          track: track,
          file: completeFile,
          etag: '"v1"',
        );
        store.saveOfflineMedia(
          serverUri: serverUri,
          expectedGeneration: store.generationFor(serverUri),
          trackId: 'track-2',
          track: secondTrack,
          file: secondFile,
          etag: '"v1"',
        );
        final oldGeneration = store.generationFor(serverUri);

        store.applySyncPages(serverUri, [
          _syncPage(
            cursor: 'reset',
            revision: 2,
            reset: true,
            changedTracks: [track, secondTrack],
          ),
        ]);

        expect(store.offlineTracks(serverUri: serverUri), isEmpty);
        expect(
          () => store.saveOfflineMedia(
            serverUri: serverUri,
            expectedGeneration: oldGeneration,
            trackId: 'track-1',
            track: track,
            file: completeFile,
            etag: '"v1"',
          ),
          throwsStateError,
        );
        expect(await completeFile.exists(), isTrue);

        store.authorizeOfflineMedia(
          serverUri,
          'track-1',
          store.generationFor(serverUri),
        );
        expect(
          store
              .offlineTracks(serverUri: serverUri)
              .map((item) => item['track_id']),
          ['track-1'],
        );
      },
    );

    test(
      'media download writes a complete file before publishing it',
      () async {
        server.listen((request) async {
          expect(request.uri.path, '/api/v2/media/track-1');
          expect(request.headers.value('X-API-Key'), 'test-key');
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.add(utf8.encode('audio-data'));
          await request.response.close();
        });

        final temporaryDirectory = await Directory.systemTemp.createTemp(
          'pikmelo-test-',
        );
        addTearDown(() => temporaryDirectory.delete(recursive: true));
        final client = PikmeloApiClient(
          serverUri: serverUri,
          apiKey: 'test-key',
        );
        addTearDown(client.close);

        final result = await client.downloadMedia(
          trackId: 'track-1',
          directory: temporaryDirectory,
          expectedBytes: 10,
        );

        expect(await result.file.readAsString(), 'audio-data');
        expect(result.file.path.endsWith('.media'), isTrue);
        expect(result.etag, '"v1"');
        expect(
          await File(
            '${temporaryDirectory.path}${Platform.pathSeparator}track-1.part',
          ).exists(),
          isFalse,
        );
      },
    );

    test('media access check uses an authenticated HEAD request', () async {
      server.listen((request) async {
        expect(request.method, 'HEAD');
        expect(request.uri.path, '/api/v2/media/track-1');
        expect(request.headers.value('X-API-Key'), 'test-key');
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      final client = PikmeloApiClient(serverUri: serverUri, apiKey: 'test-key');
      addTearDown(client.close);

      await client.checkMediaAccess('track-1');
    });

    test('only cached tracks with successful media checks are reauthorized', () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'pikmelo-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      final firstTrack = {'id': 'track-1', 'title': 'First', 'size': 10};
      final secondTrack = {'id': 'track-2', 'title': 'Second', 'size': 10};
      store.applySyncPages(serverUri, [
        _syncPage(
          cursor: 'old-cursor',
          revision: 1,
          changedTracks: [firstTrack, secondTrack],
        ),
      ]);
      for (final track in [firstTrack, secondTrack]) {
        final file = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}${track['id']}.media',
        );
        await file.writeAsString('audio-data');
        store.saveOfflineMedia(
          serverUri: serverUri,
          expectedGeneration: store.generationFor(serverUri),
          trackId: track['id']! as String,
          track: track,
          file: file,
          etag: '"v1"',
        );
      }

      final checkedTracks = <String>[];
      server.listen((request) async {
        if (request.method == 'GET' && request.uri.path == '/api/v2/sync') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'changed_tracks': [firstTrack, secondTrack],
              'playlists': [],
              'deleted_tracks': [],
              'deleted_playlists': [],
              'cursor': 'new-cursor',
              'has_more': false,
              'full_snapshot': true,
              'reset': true,
              'revision': 2,
            }),
          );
        } else if (request.method == 'HEAD' &&
            request.uri.path.startsWith('/api/v2/media/')) {
          final trackID = request.uri.path.split('/').last;
          checkedTracks.add(trackID);
          request.response.statusCode = trackID == 'track-1'
              ? HttpStatus.notFound
              : HttpStatus.ok;
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final client = PikmeloApiClient(serverUri: serverUri, apiKey: 'test-key');
      addTearDown(client.close);

      await SyncService(
        client: client,
        store: store,
        serverUri: serverUri,
      ).synchronize();

      expect(checkedTracks, ['track-1', 'track-2']);
      expect(
        store
            .offlineTracks(serverUri: serverUri)
            .map((item) => item['track_id']),
        ['track-2'],
      );
    });

    test('media download resumes with Range and the saved ETag', () async {
      server.listen((request) async {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=5-');
        expect(request.headers.value(HttpHeaders.ifRangeHeader), '"v1"');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 5-9/10',
        );
        request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
        request.response.add(utf8.encode('-data'));
        await request.response.close();
      });

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'pikmelo-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      await File(
        '${temporaryDirectory.path}${Platform.pathSeparator}track-1.part',
      ).writeAsString('audio');
      final client = PikmeloApiClient(serverUri: serverUri, apiKey: 'test-key');
      addTearDown(client.close);

      final result = await client.downloadMedia(
        trackId: 'track-1',
        directory: temporaryDirectory,
        expectedBytes: 10,
        resumeEtag: '"v1"',
      );

      expect(await result.file.readAsString(), 'audio-data');
      expect(result.bytesWritten, 5);
    });

    test(
      'changed ETag resets a partial file before saving the new ETag',
      () async {
        var requestCount = 0;
        server.listen((request) async {
          requestCount++;
          if (requestCount == 1) {
            expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=5-');
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes 5-9/10',
            );
            request.response.headers.set(HttpHeaders.etagHeader, '"v2"');
            request.response.add(utf8.encode('-new!'));
          } else {
            expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
            request.response.headers.set(HttpHeaders.etagHeader, '"v2"');
            request.response.add(utf8.encode('new-audio!'));
          }
          await request.response.close();
        });

        final temporaryDirectory = await Directory.systemTemp.createTemp(
          'pikmelo-test-',
        );
        addTearDown(() => temporaryDirectory.delete(recursive: true));
        final partialFile = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}track-1.part',
        );
        await partialFile.writeAsString('audio');
        final client = PikmeloApiClient(
          serverUri: serverUri,
          apiKey: 'test-key',
        );
        addTearDown(client.close);
        var savedEtagFileLength = -1;

        final result = await client.downloadMedia(
          trackId: 'track-1',
          directory: temporaryDirectory,
          expectedBytes: 10,
          resumeEtag: '"v1"',
          onEtag: (_) => savedEtagFileLength = partialFile.lengthSync(),
        );

        expect(requestCount, 2);
        expect(savedEtagFileLength, 0);
        expect(await result.file.readAsString(), 'new-audio!');
      },
    );

    test('concurrent requests share a single media download task', () async {
      var requestCount = 0;
      server.listen((request) async {
        requestCount++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
        request.response.add(utf8.encode('audio-data'));
        await request.response.close();
      });

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'pikmelo-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      store.applySyncPages(serverUri, [
        _syncPage(
          cursor: 'track-cursor',
          revision: 1,
          changedTracks: [
            {'id': 'track-1', 'title': 'Song', 'size': 10},
          ],
        ),
      ]);
      final client = PikmeloApiClient(serverUri: serverUri, apiKey: 'test-key');
      addTearDown(client.close);
      final downloadService = MediaDownloadService(
        client: client,
        store: store,
        cacheDirectory: temporaryDirectory,
        serverUri: serverUri,
      );
      const track = {'id': 'track-1', 'title': 'Song', 'size': 10};

      final results = await Future.wait([
        downloadService.downloadTrack(track),
        downloadService.downloadTrack(track),
      ]);

      expect(requestCount, 1);
      expect(results[0].file.path, results[1].file.path);
      expect(
        store.offlineTracks(serverUri: serverUri).single['file_path'],
        results[0].file.path,
      );
    });
  });
}

PikmeloSyncPage _syncPage({
  required String cursor,
  required int revision,
  bool reset = false,
  List<Map<String, dynamic>> changedTracks = const [],
  List<Map<String, dynamic>> playlists = const [],
}) => PikmeloSyncPage.fromJson({
  'changed_tracks': changedTracks,
  'playlists': playlists,
  'deleted_tracks': [],
  'deleted_playlists': [],
  'cursor': cursor,
  'has_more': false,
  'full_snapshot': false,
  'reset': reset,
  'revision': revision,
});
