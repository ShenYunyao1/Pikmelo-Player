import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/sync/sync_service.dart';

void main() {
  test(
    'Retry-After accepts HTTP dates and malformed values use bounded retries',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((request) async {
        calls++;
        if (calls < 3) {
          request.response.statusCode = 429;
          request.response.headers.set(
            'Retry-After',
            calls == 1
                ? HttpDate.format(
                    DateTime.now().toUtc().add(const Duration(seconds: 4)),
                  )
                : 'invalid-date',
          );
        } else {
          request.response.write('{"version":"test"}');
        }
        await request.response.close();
      });
      final waits = <Duration>[];
      final client = PikmeloApiClient(
        serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'test-key',
        retryDelay: (duration) async => waits.add(duration),
      );
      addTearDown(client.close);
      expect((await client.checkHealth())['version'], 'test');
      expect(waits.length, 2);
      expect(waits.first.inMilliseconds, inInclusiveRange(0, 4000));
      expect(waits.last, const Duration(seconds: 2));
    },
  );

  test(
    'failed pagination preserves the last committed snapshot and can retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      store.applySyncPages(uri, [_page('base')]);
      var recovered = false;
      server.listen((request) async {
        final next = request.uri.queryParameters['cursor'] == 'next';
        if (next && !recovered) {
          request.response.statusCode = 500;
        } else {
          request.response.write(
            jsonEncode({
              'changed_tracks': next
                  ? []
                  : [
                      {'id': 'new-track', 'title': 'New'},
                    ],
              'playlists': [],
              'deleted_tracks': [],
              'deleted_playlists': [],
              'cursor': next ? 'final' : 'next',
              'has_more': !next,
              'full_snapshot': false,
              'reset': false,
              'revision': 2,
            }),
          );
        }
        await request.response.close();
      });
      final client = PikmeloApiClient(serverUri: uri, apiKey: 'test-key');
      addTearDown(client.close);
      final sync = SyncService(client: client, store: store, serverUri: uri);
      await expectLater(
        sync.synchronize(),
        throwsA(isA<PikmeloApiException>()),
      );
      expect(store.cursorFor(uri), 'base');
      expect(store.tracks(uri), isEmpty);
      recovered = true;
      await sync.synchronize();
      expect(store.cursorFor(uri), 'final');
      expect(store.tracks(uri).single['id'], 'new-track');
    },
  );

  test('429 retries respect Retry-After and stop at the retry limit', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    server.listen((request) async {
      calls++;
      request.response.statusCode = 429;
      request.response.headers.set('Retry-After', '2');
      request.response.write('{"code":"RATE_LIMITED","error":"Wait"}');
      await request.response.close();
    });
    final waits = <Duration>[];
    final client = PikmeloApiClient(
      serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
      apiKey: 'test-key',
      retryDelay: (duration) async => waits.add(duration),
    );
    addTearDown(client.close);
    await expectLater(
      client.checkHealth(),
      throwsA(
        isA<PikmeloApiException>().having(
          (e) => e.retryAfter,
          'delay',
          const Duration(seconds: 2),
        ),
      ),
    );
    expect(calls, 3);
    expect(waits, [const Duration(seconds: 2), const Duration(seconds: 2)]);
  });

  test(
    'metadata response timeout terminates an unresponsive request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((_) {});
      final client = PikmeloApiClient(
        serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'test-key',
        requestTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(client.close);
      await expectLater(client.checkHealth(), throwsA(isA<TimeoutException>()));
    },
  );

  test('closing client cancels a pending Retry-After wait', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 429;
      request.response.headers.set('Retry-After', '60');
      await request.response.close();
    });
    final waiting = Completer<void>();
    final delay = Completer<void>();
    final client = PikmeloApiClient(
      serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
      apiKey: 'test-key',
      retryDelay: (_) {
        waiting.complete();
        return delay.future;
      },
    );
    final request = client.checkHealth();
    final result = expectLater(request, throwsA(isA<StateError>()));
    await waiting.future;
    client.close();
    await result.timeout(const Duration(seconds: 2));
    delay.complete();
  });

  test(
    'stale sync cannot publish after its context or generation changes',
    () async {
      final store = await LocalLibraryStore.open(databasePath: ':memory:');
      addTearDown(store.close);
      final server = Uri.parse('https://example.com');
      var current = true;
      final client = _DelayedSyncClient(server);
      addTearDown(client.close);
      final pending = SyncService(
        client: client,
        store: store,
        serverUri: server,
      ).synchronize(isCurrent: () => current);
      final assertion = expectLater(
        pending,
        throwsA(isA<SyncCancelledException>()),
      );
      current = false;
      client.page.complete(_page('stale'));
      await assertion;
      expect(store.cursorFor(server), isNull);

      final generation = store.generationFor(server);
      store.invalidateServer(server);
      expect(
        () => store.applySyncPages(server, [
          _page('old'),
        ], expectedGeneration: generation),
        throwsStateError,
      );
      expect(store.cursorFor(server), isNull);
    },
  );

  test('credential changes clear only the affected server snapshot', () async {
    final store = await LocalLibraryStore.open(databasePath: ':memory:');
    addTearDown(store.close);
    final server = Uri.parse('https://example.com');
    final other = Uri.parse('https://other.com');
    store.bindCredentials(server, 'fingerprint-a', adoptLegacy: true);
    store.applySyncPages(server, [_page('first')]);
    store.applySyncPages(other, [_page('other')]);
    store.bindCredentials(server, 'fingerprint-a');
    expect(store.cursorFor(server), 'first');
    final generation = store.generationFor(server);
    store.bindCredentials(server, 'fingerprint-b');
    expect(store.cursorFor(server), isNull);
    expect(store.playlists(server), isEmpty);
    expect(store.generationFor(server), greaterThan(generation));
    expect(store.cursorFor(other), 'other');
    store.saveSelectedServer(server);
    expect(store.selectedServer(), server);
  });
}

PikmeloSyncPage _page(String cursor) => PikmeloSyncPage.fromJson({
  'changed_tracks': [],
  'playlists': [
    {'id': 'list', 'name': 'List'},
  ],
  'deleted_tracks': [],
  'deleted_playlists': [],
  'cursor': cursor,
  'has_more': false,
  'full_snapshot': true,
  'reset': false,
  'revision': 1,
});

class _DelayedSyncClient extends PikmeloApiClient {
  _DelayedSyncClient(Uri uri) : super(serverUri: uri, apiKey: 'test-key');
  final page = Completer<PikmeloSyncPage>();

  @override
  Future<PikmeloSyncPage> fetchSyncPage({String? cursor, int limit = 100}) =>
      page.future;
}
