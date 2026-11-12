import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pikmelo_player/app/app_dependencies.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'on-demand playlist downloads, prefetches, reopens offline and migrates media',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('按需播放与目录迁移验证'))),
      );
      final root = await Directory.systemTemp.createTemp('pikmelo-demand-');
      final database = '${root.path}/library.sqlite';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final audio = _wave();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.set('ETag', '"native-wave"');
        request.response.add(audio);
        await request.response.close();
      });
      final store = await LocalLibraryStore.open(databasePath: database);
      store.saveSelectedServer(uri);
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [
            for (var i = 0; i < 2; i++)
              {'id': 'native-$i', 'title': '按需曲目 $i', 'size': audio.length},
          ],
          playlists: [
            {
              'id': 'native-list',
              'name': '按需播放歌单',
              'track_ids': ['native-0', 'native-1'],
            },
          ],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'native',
          hasMore: false,
          fullSnapshot: true,
          reset: false,
          revision: 1,
        ),
      ]);
      store.close();
      AppDependencies create() => AppDependencies(
        keyStore: _Keys(),
        openStore: () => LocalLibraryStore.open(databasePath: database),
        createClient: (connection, key) =>
            PikmeloApiClient(serverUri: connection.uri, apiKey: key),
      );
      var dependencies = create();
      try {
        await dependencies.initializePlatformPlayback();
        await dependencies.playback.setVolume(0);
        var connection = dependencies.createConnectionController();
        await connection.initialize();
        final storage = connection.mediaStorage!;
        expect(storage.networkKnown, isTrue);
        const tree = String.fromEnvironment('PIKMELO_TEST_DOCUMENT_TREE');
        const pickDirectory = bool.fromEnvironment(
          'PIKMELO_TEST_PICK_DIRECTORY',
        );
        final destination = pickDirectory
            ? (await storage.store.files.chooseDirectory())!
            : tree.isEmpty
            ? '${root.path}/custom'
            : tree;
        await connection.changeMediaDirectory(destination, migrate: false);
        expect(
          connection
              .entriesFor('native-list')
              .every((entry) => !entry.downloaded),
          isTrue,
        );
        await connection.playPlaylist('native-list', 0);
        expect(dependencies.playback.state.error, isNull);
        await _until(
          tester,
          () => dependencies.playback.state.position > Duration.zero,
        );
        await _until(tester, () => storage.store.offlineTracks().length == 2);
        expect(requests, 2);
        expect(dependencies.playback.current!.path, startsWith(destination));
        expect(
          storage.store.mediaInventory().every((row) => row['pinned'] == 0),
          isTrue,
        );
        await dependencies.dispose();
        await server.close(force: true);
        dependencies = create();
        await dependencies.initializePlatformPlayback();
        await dependencies.playback.setVolume(0);
        connection = dependencies.createConnectionController();
        await connection.initialize();
        expect(connection.mediaStorage!.directory, destination);
        await connection.playPlaylist('native-list', 1);
        await _until(
          tester,
          () => dependencies.playback.state.position > Duration.zero,
        );
        expect(requests, 2);
        final local = '${root.path}/migrated';
        await connection.changeMediaDirectory(local, migrate: true);
        expect(
          connection.mediaStorage!.store.offlineTracks().every(
            (row) => (row['file_path'] as String).startsWith(local),
          ),
          isTrue,
        );
        await connection.playPlaylist('native-list', 0);
        await _until(
          tester,
          () => dependencies.playback.state.position > Duration.zero,
        );
        for (final id in ['native-0', 'native-1']) {
          await connection.downloads!.remove(id);
        }
        expect(connection.mediaStorage!.store.offlineTracks(), isEmpty);
      } finally {
        await dependencies.dispose();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Native download/playback did not reach the expected state.');
}

Uint8List _wave() {
  const size = 44100 * 2 * 8;
  final data = ByteData(44 + size);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, size + 36, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 88200, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, size, Endian.little);
  return data.buffer.asUint8List();
}

class _Keys extends ApiKeyStore {
  @override
  Future<String?> read(String serverKey) async => 'native-test-key';
}
