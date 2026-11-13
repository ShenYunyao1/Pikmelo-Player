import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../settings/models/server_connection.dart';
import '../server/sync_page.dart';
import 'media_files.dart';
import '../../shared/diagnostics.dart';

class LocalLibraryStore {
  LocalLibraryStore._(this._database);

  final Database _database;
  final files = MediaFiles();

  String _metadataKey(String path) =>
      'local_metadata_${sha256.convert(utf8.encode(path))}';
  String _metadataFingerprint(String path) {
    if (files.isDocument(path)) return '${files.length(path)}';
    final stat = FileStat.statSync(path);
    return '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
  }

  String _lyricsKey(String path) =>
      'local_lyrics_${sha256.convert(utf8.encode(path))}';
  Map<String, dynamic>? localMetadata(String path) =>
      _localResource(path, _metadataKey(path));
  Map<String, dynamic>? localLyrics(String path) {
    final result = _localResource(path, _lyricsKey(path));
    if (Diagnostics.enabled) {
      Diagnostics.event('lyrics.cache.read', {
        'file': Diagnostics.identifier(path),
        'hit': result != null,
      });
    }
    return result;
  }

  Map<String, dynamic>? _localResource(String path, String key) {
    try {
      final raw = setting(key);
      if (raw == null) return null;
      final value = jsonDecode(raw) as Map;
      if (value['schema'] != 1) return null;
      if (value['fingerprint'] != _metadataFingerprint(path)) return null;
      return Map<String, dynamic>.from(value['metadata'] as Map);
    } catch (_) {
      return null;
    }
  }

  void saveLocalMetadata(String path, Map<String, dynamic> metadata) =>
      _saveResource(path, _metadataKey(path), metadata);
  void saveLocalLyrics(String path, String? text) {
    _saveResource(path, _lyricsKey(path), {'text': text});
    if (Diagnostics.enabled) {
      Diagnostics.event('lyrics.cache.write', {
        'file': Diagnostics.identifier(path),
        'chars': text?.length ?? 0,
      });
    }
  }

  void _saveResource(String path, String key, Map<String, dynamic> metadata) =>
      saveSetting(
        key,
        jsonEncode({
          'schema': 1,
          'fingerprint': _metadataFingerprint(path),
          'metadata': metadata,
        }),
      );

  static Future<LocalLibraryStore> open({String? databasePath}) async {
    final path = databasePath ?? await _defaultDatabasePath();
    final database = sqlite3.open(path);
    database.execute('PRAGMA journal_mode = WAL');
    database.execute('PRAGMA foreign_keys = ON');
    database.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        server_key TEXT PRIMARY KEY,
        cursor TEXT NOT NULL,
        revision INTEGER NOT NULL
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS sync_generation (
        server_key TEXT PRIMARY KEY,
        generation INTEGER NOT NULL DEFAULT 0
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS tracks (
        server_key TEXT NOT NULL,
        id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (server_key, id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        server_key TEXT NOT NULL,
        id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (server_key, id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS offline_media (
        server_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        track_data TEXT NOT NULL,
        file_path TEXT NOT NULL,
        etag TEXT,
        authorized INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (server_key, track_id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS download_tasks (
        server_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        etag TEXT,
        PRIMARY KEY (server_key, track_id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    final downloadColumns = database.select(
      'PRAGMA table_info(download_tasks)',
    );
    if (!downloadColumns.any((column) => column['name'] == 'generation')) {
      database.execute(
        'ALTER TABLE download_tasks ADD COLUMN generation INTEGER',
      );
    }
    database.execute('''
      CREATE TABLE IF NOT EXISTS server_credentials (
        server_key TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS download_queue (
        server_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        status TEXT NOT NULL,
        received INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        PRIMARY KEY (server_key, track_id)
      )
    ''');
    database.execute(
      'CREATE TABLE IF NOT EXISTS pending_file_deletions (path TEXT PRIMARY KEY)',
    );
    database.execute('''
      CREATE TABLE IF NOT EXISTS media_retention (
        server_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 1,
        last_used INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (server_key, track_id)
      )
    ''');
    database.execute('''
      INSERT OR IGNORE INTO media_retention (server_key, track_id)
      SELECT server_key, track_id FROM offline_media
    ''');
    return LocalLibraryStore._(database);
  }

  Uri? selectedServer() {
    final rows = _database.select(
      "SELECT value FROM app_settings WHERE key = 'selected_server'",
    );
    return rows.isEmpty ? null : Uri.parse(rows.single['value'] as String);
  }

  String? setting(String key) {
    final rows = _database.select(
      'SELECT value FROM app_settings WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  void saveSetting(String key, String value) {
    final elapsed = Stopwatch()..start();
    _database.execute(
      'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
      [key, value],
    );
    if (Diagnostics.enabled) {
      Diagnostics.event('settings.write', {
        'kind': key.startsWith('playback_session_')
            ? 'playback_session'
            : key == 'playback_preferences'
            ? key
            : 'other',
        'chars': value.length,
        'us': elapsed.elapsedMicroseconds,
      });
    }
  }

  void retainMedia(Uri uri, String id, {required bool pinned}) =>
      _database.execute(
        '''
    INSERT INTO media_retention (server_key, track_id, pinned, last_used) VALUES (?, ?, ?, ?)
    ON CONFLICT(server_key, track_id) DO UPDATE SET
      pinned = MAX(media_retention.pinned, excluded.pinned), last_used = excluded.last_used
    ''',
        [
          _serverKey(uri),
          id,
          pinned ? 1 : 0,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );

  bool mediaPinned(Uri uri, String id) {
    final rows = _database.select(
      'SELECT pinned FROM media_retention WHERE server_key = ? AND track_id = ?',
      [_serverKey(uri), id],
    );
    return rows.isEmpty || rows.single['pinned'] == 1;
  }

  List<Map<String, Object?>> mediaInventory() => _database.select('''
    SELECT offline_media.*, COALESCE(media_retention.pinned, 1) AS pinned,
      COALESCE(media_retention.last_used, 0) AS last_used
    FROM offline_media LEFT JOIN media_retention USING (server_key, track_id)
    ORDER BY last_used
  ''');

  void relocateMedia(String oldPath, String newPath) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'UPDATE offline_media SET file_path = ? WHERE file_path = ?',
        [newPath, oldPath],
      );
      _database.execute(
        'INSERT OR IGNORE INTO pending_file_deletions (path) VALUES (?)',
        [oldPath],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void saveSelectedServer(Uri uri) => _database.execute(
    "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('selected_server', ?)",
    [uri.toString()],
  );

  void bindCredentials(
    Uri uri,
    String fingerprint, {
    bool adoptLegacy = false,
  }) {
    final key = _serverKey(uri);
    _database.execute('BEGIN IMMEDIATE');
    try {
      final rows = _database.select(
        'SELECT fingerprint FROM server_credentials WHERE server_key = ?',
        [key],
      );
      final previous = rows.isEmpty ? null : rows.single['fingerprint'];
      if (previous != fingerprint) {
        if (previous != null || !adoptLegacy) _invalidateServer(key);
        _database.execute(
          'INSERT OR REPLACE INTO server_credentials (server_key, fingerprint) VALUES (?, ?)',
          [key, fingerprint],
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void invalidateServer(Uri uri) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _invalidateServer(_serverKey(uri));
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _invalidateServer(String key) {
    _database.execute(
      'UPDATE download_tasks SET generation = ? WHERE server_key = ? AND generation IS NULL',
      [_generationInTransaction(key), key],
    );
    _database.execute(
      '''
      INSERT INTO sync_generation (server_key, generation) VALUES (?, 1)
      ON CONFLICT(server_key) DO UPDATE SET generation = generation + 1
    ''',
      [key],
    );
    for (final table in [
      'tracks',
      'playlists',
      'sync_state',
      'download_queue',
    ]) {
      _database.execute('DELETE FROM $table WHERE server_key = ?', [key]);
    }
    _database.execute(
      'UPDATE offline_media SET authorized = 0 WHERE server_key = ?',
      [key],
    );
    // Partial tasks remain tracked so the next reset can remove their files.
  }

  String? cursorFor(Uri serverUri) {
    final result = _database.select(
      'SELECT cursor FROM sync_state WHERE server_key = ?',
      [_serverKey(serverUri)],
    );
    return result.isEmpty ? null : result.first['cursor'] as String;
  }

  int generationFor(Uri serverUri) =>
      _generationInTransaction(_serverKey(serverUri));

  List<String> applySyncPages(
    Uri serverUri,
    List<PikmeloSyncPage> pages, {
    int? expectedGeneration,
  }) {
    if (pages.isEmpty || pages.last.cursor.isEmpty) {
      throw const FormatException(
        'The sync response did not include a final cursor.',
      );
    }
    final serverKey = _serverKey(serverUri);
    final staleDownloadPaths = <String>[];
    _database.execute('BEGIN IMMEDIATE');
    try {
      if (expectedGeneration != null &&
          _generationInTransaction(serverKey) != expectedGeneration) {
        throw StateError('The sync authorization context changed.');
      }
      final reset = pages.any((page) => page.reset);
      if (reset) {
        _database.execute(
          '''
            INSERT INTO sync_generation (server_key, generation)
            VALUES (?, 1)
            ON CONFLICT(server_key) DO UPDATE SET generation = generation + 1
          ''',
          [serverKey],
        );
        _database.execute('DELETE FROM tracks WHERE server_key = ?', [
          serverKey,
        ]);
        _database.execute('DELETE FROM playlists WHERE server_key = ?', [
          serverKey,
        ]);
        _database.execute(
          'UPDATE offline_media SET authorized = 0 WHERE server_key = ?',
          [serverKey],
        );
      }

      for (final page in pages) {
        for (final track in page.changedTracks) {
          final id = _entityId(track, 'track');
          final cached = _database.select(
            'SELECT track_data, file_path FROM offline_media WHERE server_key = ? AND track_id = ?',
            [serverKey, id],
          );
          if (cached.isNotEmpty) {
            final previous =
                jsonDecode(cached.first['track_data'] as String) as Map;
            final changed =
                (track['content_hash'] != null &&
                    previous['content_hash'] != track['content_hash']) ||
                (track['size'] != null && previous['size'] != track['size']);
            if (changed) {
              staleDownloadPaths.add(cached.first['file_path'] as String);
              _database.execute(
                'DELETE FROM offline_media WHERE server_key = ? AND track_id = ?',
                [serverKey, id],
              );
            }
          }
          _database.execute(
            'INSERT OR REPLACE INTO tracks (server_key, id, data) VALUES (?, ?, ?)',
            [serverKey, id, jsonEncode(track)],
          );
          _database.execute(
            'UPDATE offline_media SET track_data = ? WHERE server_key = ? AND track_id = ?',
            [jsonEncode(track), serverKey, id],
          );
        }
        for (final playlist in page.playlists) {
          final id = _entityId(playlist, 'playlist');
          _database.execute(
            'INSERT OR REPLACE INTO playlists (server_key, id, data) VALUES (?, ?, ?)',
            [serverKey, id, jsonEncode(playlist)],
          );
        }
        for (final id in page.deletedTracks) {
          final task = _database.select(
            'SELECT file_path FROM download_tasks WHERE server_key = ? AND track_id = ?',
            [serverKey, id],
          );
          if (task.isNotEmpty) {
            staleDownloadPaths.add(task.first['file_path'] as String);
          }
          _database.execute(
            'DELETE FROM download_tasks WHERE server_key = ? AND track_id = ?',
            [serverKey, id],
          );
          _database.execute(
            'DELETE FROM tracks WHERE server_key = ? AND id = ?',
            [serverKey, id],
          );
          _database.execute(
            'UPDATE offline_media SET authorized = 0 WHERE server_key = ? AND track_id = ?',
            [serverKey, id],
          );
        }
        for (final id in page.deletedPlaylists) {
          _database.execute(
            'DELETE FROM playlists WHERE server_key = ? AND id = ?',
            [serverKey, id],
          );
        }
      }

      if (reset) {
        final tasks = _database.select(
          'SELECT file_path FROM download_tasks WHERE server_key = ?',
          [serverKey],
        );
        for (final task in tasks) {
          staleDownloadPaths.add(task['file_path'] as String);
        }
        _database.execute('DELETE FROM download_tasks WHERE server_key = ?', [
          serverKey,
        ]);
      }

      _database.execute(
        'INSERT OR REPLACE INTO sync_state (server_key, cursor, revision) VALUES (?, ?, ?)',
        [serverKey, pages.last.cursor, pages.last.revision],
      );
      for (final path in staleDownloadPaths) {
        _database.execute(
          'INSERT OR IGNORE INTO pending_file_deletions (path) VALUES (?)',
          [path],
        );
      }
      _database.execute('COMMIT');
      return staleDownloadPaths;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String? saveOfflineMedia({
    required Uri serverUri,
    required int expectedGeneration,
    required String trackId,
    required Map<String, dynamic> track,
    required File file,
    String? etag,
    String? location,
  }) {
    final serverKey = _serverKey(serverUri);
    _database.execute('BEGIN IMMEDIATE');
    try {
      final trackExists = _database.select(
        'SELECT 1 FROM tracks WHERE server_key = ? AND id = ?',
        [_serverKey(serverUri), trackId],
      );
      if (trackExists.isEmpty) {
        throw StateError('The track is no longer authorized for this server.');
      }
      if (_generationInTransaction(serverKey) != expectedGeneration) {
        throw StateError(
          'The library permissions changed during the download.',
        );
      }
      final existing = _database.select(
        'SELECT file_path FROM offline_media WHERE server_key = ? AND track_id = ?',
        [serverKey, trackId],
      );
      _database.execute(
        '''
          INSERT OR REPLACE INTO offline_media
            (server_key, track_id, track_data, file_path, etag, authorized)
          VALUES (?, ?, ?, ?, ?, 1)
        ''',
        [serverKey, trackId, jsonEncode(track), location ?? file.path, etag],
      );
      _database.execute(
        'DELETE FROM download_tasks WHERE server_key = ? AND track_id = ?',
        [serverKey, trackId],
      );
      _database.execute(
        'INSERT OR IGNORE INTO media_retention (server_key, track_id) VALUES (?, ?)',
        [serverKey, trackId],
      );
      if (existing.isNotEmpty &&
          existing.first['file_path'] != (location ?? file.path)) {
        _database.execute(
          'INSERT OR IGNORE INTO pending_file_deletions (path) VALUES (?)',
          [existing.first['file_path']],
        );
      }
      _database.execute('COMMIT');
      return existing.isEmpty ? null : existing.first['file_path'] as String;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void savePartialEtag(
    Uri serverUri,
    int expectedGeneration,
    String trackId,
    String? etag,
    String partialPath,
  ) {
    final serverKey = _serverKey(serverUri);
    _database.execute('BEGIN IMMEDIATE');
    try {
      final trackExists = _database.select(
        'SELECT 1 FROM tracks WHERE server_key = ? AND id = ?',
        [serverKey, trackId],
      );
      if (trackExists.isEmpty ||
          _generationInTransaction(serverKey) != expectedGeneration) {
        _database.execute('ROLLBACK');
        return;
      }
      final previous = _database.select(
        'SELECT file_path FROM download_tasks WHERE server_key = ? AND track_id = ?',
        [serverKey, trackId],
      );
      if (previous.isNotEmpty && previous.first['file_path'] != partialPath) {
        _database.execute(
          'INSERT OR IGNORE INTO pending_file_deletions (path) VALUES (?)',
          [previous.first['file_path']],
        );
      }
      _database.execute(
        '''
          INSERT OR REPLACE INTO download_tasks
            (server_key, track_id, file_path, etag, generation)
          VALUES (?, ?, ?, ?, ?)
        ''',
        [serverKey, trackId, partialPath, etag, expectedGeneration],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, Object?>? downloadTask(Uri serverUri, String trackId) {
    final result = _database.select(
      'SELECT * FROM download_tasks WHERE server_key = ? AND track_id = ?',
      [_serverKey(serverUri), trackId],
    );
    return result.isEmpty ? null : Map<String, Object?>.from(result.first);
  }

  List<Map<String, Object?>> downloadTasks(Uri uri) => _database
      .select('SELECT * FROM download_tasks WHERE server_key = ?', [
        _serverKey(uri),
      ])
      .map((row) => Map<String, Object?>.from(row))
      .toList();

  List<Map<String, Object?>> downloadQueue(Uri uri) => _database
      .select(
        'SELECT download_queue.* FROM download_queue INNER JOIN tracks ON tracks.server_key = download_queue.server_key AND tracks.id = download_queue.track_id WHERE download_queue.server_key = ? ORDER BY download_queue.rowid',
        [_serverKey(uri)],
      )
      .map((row) => Map<String, Object?>.from(row))
      .toList();

  void saveDownloadQueue(
    Uri uri,
    String id,
    String status,
    int received,
    String? error,
  ) => _database.execute(
    '''
    INSERT INTO download_queue (server_key, track_id, status, received, error) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(server_key, track_id) DO UPDATE SET status=excluded.status, received=excluded.received, error=excluded.error
  ''',
    [_serverKey(uri), id, status, received, error],
  );

  void removeDownloadTask(Uri uri, String id) {
    _database.execute(
      'DELETE FROM download_tasks WHERE server_key = ? AND track_id = ?',
      [_serverKey(uri), id],
    );
    _database.execute(
      'DELETE FROM download_queue WHERE server_key = ? AND track_id = ?',
      [_serverKey(uri), id],
    );
  }

  void removeOfflineMedia(Uri uri, String id) {
    _database.execute(
      'DELETE FROM offline_media WHERE server_key = ? AND track_id = ?',
      [_serverKey(uri), id],
    );
    _database.execute(
      'DELETE FROM media_retention WHERE server_key = ? AND track_id = ?',
      [_serverKey(uri), id],
    );
  }

  void revokeOfflineMedia(Uri uri, String id) => _database.execute(
    'UPDATE offline_media SET authorized = 0 WHERE server_key = ? AND track_id = ?',
    [_serverKey(uri), id],
  );

  List<String> pendingFileDeletions() => _database
      .select('SELECT path FROM pending_file_deletions')
      .map((row) => row['path'] as String)
      .toList();

  void completeFileDeletion(String path) {
    _database.execute('DELETE FROM pending_file_deletions WHERE path = ?', [
      path,
    ]);
    _database.execute('DELETE FROM app_settings WHERE key IN (?, ?)', [
      _metadataKey(path),
      _lyricsKey(path),
    ]);
  }

  List<Map<String, Object?>> offlineTracks({
    Uri? serverUri,
    bool authorizedOnly = true,
  }) {
    final where = [
      if (serverUri != null) 'server_key = ?',
      if (authorizedOnly) 'authorized = 1',
    ];
    final parameters = [if (serverUri != null) _serverKey(serverUri)];
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return _database
        .select(
          'SELECT * FROM offline_media $clause ORDER BY server_key, track_id',
          parameters,
        )
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
  }

  Map<String, Object?>? offlineMedia(Uri uri, String id) {
    final rows = _database.select(
      '''
      SELECT offline_media.file_path, tracks.data FROM offline_media
      INNER JOIN tracks ON tracks.server_key = offline_media.server_key AND tracks.id = offline_media.track_id
      WHERE offline_media.server_key = ? AND offline_media.track_id = ? AND offline_media.authorized = 1
    ''',
      [_serverKey(uri), id],
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  List<String> offlineTracksNeedingMediaAuthorization(Uri serverUri) {
    return _database
        .select(
          '''
            SELECT offline_media.track_id
            FROM offline_media
            INNER JOIN tracks
              ON tracks.server_key = offline_media.server_key
              AND tracks.id = offline_media.track_id
            WHERE offline_media.server_key = ? AND offline_media.authorized = 0
            ORDER BY offline_media.track_id
          ''',
          [_serverKey(serverUri)],
        )
        .map((row) => row['track_id'] as String)
        .toList(growable: false);
  }

  void authorizeOfflineMedia(
    Uri serverUri,
    String trackId,
    int expectedGeneration,
  ) {
    final serverKey = _serverKey(serverUri);
    _database.execute('BEGIN IMMEDIATE');
    try {
      if (_generationInTransaction(serverKey) != expectedGeneration) {
        _database.execute('ROLLBACK');
        return;
      }
      _database.execute(
        '''
          UPDATE offline_media
          SET authorized = 1
          WHERE server_key = ?
            AND track_id = ?
            AND authorized = 0
            AND EXISTS (
              SELECT 1 FROM tracks
              WHERE tracks.server_key = offline_media.server_key
                AND tracks.id = offline_media.track_id
            )
        ''',
        [serverKey, trackId],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Map<String, dynamic>> playlists(Uri serverUri) {
    return _database
        .select('SELECT data FROM playlists WHERE server_key = ? ORDER BY id', [
          _serverKey(serverUri),
        ])
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['data'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic>? track(Uri serverUri, String id) {
    final rows = _database.select(
      'SELECT data FROM tracks WHERE server_key = ? AND id = ?',
      [_serverKey(serverUri), id],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['data'] as String) as Map,
          );
  }

  List<Map<String, dynamic>> tracks(Uri serverUri) {
    return _database
        .select('SELECT data FROM tracks WHERE server_key = ? ORDER BY id', [
          _serverKey(serverUri),
        ])
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['data'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  void close() => _database.close();

  static Future<String> _defaultDatabasePath() async {
    final directory = await getApplicationSupportDirectory();
    final appDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}PikmeloPlayer',
    );
    await appDirectory.create(recursive: true);
    return '${appDirectory.path}${Platform.pathSeparator}library.sqlite';
  }

  static String serverKey(Uri uri) {
    return ServerConnection.serverKey(uri);
  }

  static String _serverKey(Uri uri) => serverKey(uri);

  int _generationInTransaction(String serverKey) {
    final result = _database.select(
      'SELECT generation FROM sync_generation WHERE server_key = ?',
      [serverKey],
    );
    return result.isEmpty ? 0 : result.first['generation'] as int;
  }

  static String _entityId(Map<String, dynamic> entity, String kind) {
    final id = entity['id'];
    if (id is! String || id.isEmpty) {
      throw FormatException('The $kind response did not include an ID.');
    }
    return id;
  }
}
