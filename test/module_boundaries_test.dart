import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/library/library_repository.dart';
import 'package:pikmelo_player/library/models/playlist.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/settings/models/server_connection.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('models retain unknown fields and handle absent optional metadata', () {
    final track = Track.fromJson({'id': 'track-1', 'future_field': 7});
    expect(track.title, '未命名曲目');
    expect(track.size, isNull);
    expect(track.missing, isFalse);
    expect(track.toJson()['future_field'], 7);

    final playlist = Playlist.fromJson({'id': 'playlist-1'});
    expect(playlist.name, '未命名歌单');
    expect(playlist.trackIds, isEmpty);
    expect(playlist.unavailableTrackIds, isEmpty);
    expect(playlist.readOnly, isFalse);
    expect(
      () => Track.fromJson({'title': 'Missing ID'}),
      throwsFormatException,
    );
    expect(() => Playlist.fromJson({'id': ''}), throwsFormatException);
  });

  test('connection identity preserves server prefix and validation rules', () {
    final connection = ServerConnection(
      Uri.parse('https://example.com/music/'),
    );
    // Existing SQLite rows use this exact key, including empty URI components.
    expect(connection.key, 'https://example.com/music?#');
    expect(LocalLibraryStore.serverKey(connection.uri), connection.key);
    expect(
      () => ServerConnection(Uri.parse('http://example.com')),
      throwsArgumentError,
    );
    expect(
      () => ServerConnection(Uri.parse('https://example.com?key=secret')),
      throwsArgumentError,
    );
    expect(ServerConnection(Uri.parse('http://127.0.0.1:8000')).uri.port, 8000);
  });

  test('repository reads and reopens existing JSON database rows', () async {
    final directory = await Directory.systemTemp.createTemp('pikmelo-legacy-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}library.sqlite';
    final server = Uri.parse('https://example.com/music');
    final legacy = sqlite3.open(path);
    legacy.execute(
      'CREATE TABLE download_tasks (server_key TEXT NOT NULL, track_id TEXT NOT NULL, file_path TEXT NOT NULL, etag TEXT, PRIMARY KEY (server_key, track_id))',
    );
    legacy.execute('INSERT INTO download_tasks VALUES (?, ?, ?, ?)', [
      'https://example.com/music?#',
      'track-1',
      '${directory.path}/track-1.part',
      '"legacy"',
    ]);
    for (final table in ['tracks', 'playlists']) {
      legacy.execute('''
        CREATE TABLE $table (
          server_key TEXT NOT NULL,
          id TEXT NOT NULL,
          data TEXT NOT NULL,
          PRIMARY KEY (server_key, id)
        )
      ''');
    }
    legacy.execute('INSERT INTO tracks VALUES (?, ?, ?)', [
      'https://example.com/music?#',
      'track-1',
      jsonEncode({'id': 'track-1', 'title': 'Legacy song', 'future_field': 9}),
    ]);
    legacy.execute('INSERT INTO playlists VALUES (?, ?, ?)', [
      'https://example.com/music?#',
      'playlist-1',
      jsonEncode({
        'id': 'playlist-1',
        'name': 'Legacy list',
        'track_ids': ['track-1', 'missing-track', 'track-1'],
        'unavailable_track_ids': ['missing-track'],
      }),
    ]);
    legacy.close();

    for (var attempt = 0; attempt < 2; attempt++) {
      final store = await LocalLibraryStore.open(databasePath: path);
      try {
        final repository = LibraryRepository(store);
        if (attempt == 0) store.saveSelectedServer(server);
        expect(store.downloadTask(server, 'track-1')!['generation'], isNull);
        expect(store.selectedServer(), server);
        expect(repository.tracks(server).single.title, 'Legacy song');
        expect(repository.tracks(server).single.toJson()['future_field'], 9);
        final playlist = repository.playlists(server).single;
        expect(playlist.trackIds, ['track-1', 'missing-track', 'track-1']);
        expect(playlist.unavailableTrackIds, ['missing-track']);
        final entries = repository.playlistEntries(server, playlist);
        expect(entries.map((entry) => entry.id), [
          'track-1',
          'missing-track',
          'track-1',
        ]);
        expect(entries[1].unavailable, isTrue);
        expect(entries.first.unavailable, isFalse);
        expect(entries.first.canDownload, isFalse);
        expect(repository.playlists(Uri.parse('https://other.com')), isEmpty);
      } finally {
        store.close();
      }
    }
  });
}
