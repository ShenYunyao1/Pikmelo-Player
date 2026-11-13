import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../downloads/download_manager.dart';
import '../infrastructure/server/pikmelo_api_client.dart';
import '../infrastructure/storage/api_key_store.dart';
import '../infrastructure/storage/local_library_store.dart';
import '../library/library_repository.dart';
import '../library/models/track.dart';
import '../library/models/playlist.dart';
import '../library/models/playlist_entry.dart';
import '../playback/models/playback_item.dart';
import '../playback/playback_controller.dart';
import '../sync/sync_service.dart';
import 'models/server_connection.dart';
import 'media_storage_controller.dart';
import '../updates/update_controller.dart';
import '../artwork/artwork_service.dart';
import '../playback/playback_session.dart';
import '../artwork/embedded_resources.dart';

typedef ApiClientFactory = PikmeloApiClient Function(
  ServerConnection connection,
  String apiKey,
);
typedef RestoredConnection = ({Uri serverUri, String? apiKey});

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this._keyStore,
    required this._openStore,
    required this._createClient,
    this._cacheDirectory,
    this.playback,
    this.networkReader,
    this.updates,
  }) {
    playback?.resolveSource = _prepareSource;
    playback?.cancelPreparation = () => _downloads?.cancelPreparation();
    playback?.addListener(_playbackChanged);
    playback?.loadMetadata = (item) => item.serverUri == serverUri
        ? metadataFor(item.track.id)
        : Future.value();
    playback?.loadArtwork = (item) => item.serverUri == serverUri
        ? artworkFor(item.track.id)
        : Future.value();
  }

  final ApiKeyStore _keyStore;
  final Future<LocalLibraryStore> Function() _openStore;
  final ApiClientFactory _createClient;
  final Future<Directory> Function()? _cacheDirectory;
  final PlaybackController? playback;
  final UpdateController? updates;
  final Future<Map<String, bool>> Function()? networkReader;
  Future<void> _playbackReset = Future.value();
  DownloadManager? _downloads;
  MediaStorageController? mediaStorage;
  String? _prefetchKey;
  int _networkRevision = -1;
  Future<void>? _trimming;
  Future<void> _downloadShutdown = Future.value();
  PikmeloApiClient? _activeClient;
  LibraryRepository? _library;
  ServerConnection _connection = ServerConnection(ServerConnection.defaultUri);
  String? _apiKey;
  String? _scope;
  int _version = 0;
  bool _disposed = false;
  bool _busy = false;
  bool _connected = false;
  String _status = '尚未连接';
  String? _error;
  List<Playlist> _playlists = const [];
  Future<void> _configurationQueue = Future.value();
  Future<void>? _syncFuture;
  Future<RestoredConnection?>? _initialization;
  final _embedded = EmbeddedResourceReader();
  late final _artwork = ArtworkService(readEmbedded: _embedded.read);
  Future<void>? _metadataWork;
  bool _metadataAgain = false;

  void _loadLocalMetadata(
    LocalLibraryStore store,
    ServerConnection connection,
  ) {
    if (_metadataWork != null) {
      _metadataAgain = true;
      return;
    }
    final scope = _scope;
    _metadataWork =
        () async {
          do {
            _metadataAgain = false;
            final rows = store.offlineTracks(serverUri: connection.uri);
            for (final row in rows) {
              if (_disposed || scope != _scope) return;
              final id = row['track_id'] as String;
              await metadataFor(id);
            }
          } while (_metadataAgain && !_disposed && scope == _scope);
        }().catchError((Object _, StackTrace _) {}).whenComplete(() {
          _metadataWork = null;
          if (_metadataAgain && !_disposed && _library != null) {
            _loadLocalMetadata(store, _connection);
          }
        });
  }

  Future<Track?> metadataFor(String id) async {
    final scope = _scope;
    final library = _library;
    final store = mediaStorage?.store;
    if (_disposed || library == null || store == null) return null;
    final path = library.offlineSource(serverUri, id);
    if (path != null && store.localMetadata(path) == null) {
      final resource = await _embedded.read(path, store.files);
      if (_disposed ||
          scope != _scope ||
          _library?.offlineSource(serverUri, id) != path) {
        return null;
      }
      final metadata = <String, dynamic>{
        'artist': null,
        'album': null,
        'duration_ms': null,
        'format': null,
        'bitrate_kbps': null,
        'sample_rate': null,
        'channels': null,
        'bits_per_sample': null,
        'genre': null,
        'comment': null,
        ...resource.metadata,
      };
      if (metadata['title'] == null ||
          (metadata['title'] as String).trim().isEmpty) {
        metadata.remove('title');
      }
      store.saveLocalMetadata(path, metadata);
      playback?.updateMetadata(serverUri, library.tracks(serverUri));
      notifyListeners();
    }
    return library
        .tracks(serverUri)
        .where((track) => track.id == id)
        .firstOrNull;
  }

  PlaybackSession? _playbackSession;
  bool get restorePlaybackEnabled =>
      mediaStorage?.store.setting('restore_playback_session') != 'false';
  void setRestorePlayback(bool value) {
    final session = _playbackSession;
    if (session != null) {
      session.setEnabled(value);
    } else {
      mediaStorage?.store.saveSetting('restore_playback_session', '$value');
    }
    notifyListeners();
  }

  Future<Uint8List?> artworkFor(String id) {
    final library = _library;
    final storage = mediaStorage;
    final scope = _scope;
    final key = _apiKey;
    if (_disposed ||
        library == null ||
        storage == null ||
        scope == null ||
        key == null) {
      return Future.value();
    }
    final tracks = library
        .tracks(serverUri)
        .where((track) => track.id == id && !track.missing && !track.removed);
    if (tracks.isEmpty) return Future.value();
    final track = tracks.first;
    final path = library.offlineSource(serverUri, id);
    return _artwork.load(
      scope: scope,
      revision: jsonEncode(track.toJson()),
      path: path,
      coverId: track.coverId,
      files: storage.store.files,
      retryToken: '${storage.networkRevision}',
      allowed: () =>
          !_disposed &&
          _scope == scope &&
          _library!
              .tracks(serverUri)
              .any(
                (track) => track.id == id && !track.missing && !track.removed,
              ),
      fetchCover: (id) => _fetchArtwork(id, scope, key),
    );
  }

  Future<Uint8List?> playlistArtwork(String id) async {
    final scope = _scope;
    final key = _apiKey;
    final storage = mediaStorage;
    if (_disposed || scope == null || key == null || storage == null) {
      return null;
    }
    final matches = _playlists.where(
      (playlist) => playlist.id == id && !playlist.subscriptionInvalid,
    );
    if (matches.isEmpty) return null;
    final playlist = matches.first;
    final coverId = playlist.coverId;
    bool allowed() =>
        !_disposed &&
        _scope == scope &&
        _playlists.any(
          (p) => p.id == id && !p.subscriptionInvalid && p.coverId == coverId,
        );
    if (coverId != null) {
      final bytes = await _artwork.load(
        scope: scope,
        revision: jsonEncode(playlist.toJson()),
        path: null,
        coverId: coverId,
        files: storage.store.files,
        retryToken: '${storage.networkRevision}',
        allowed: allowed,
        fetchCover: (id) => _fetchArtwork(id, scope, key),
      );
      if (!allowed()) return null;
      if (bytes != null) return bytes;
    }
    final entries = entriesFor(id)
        .where((entry) => !entry.unavailable && entry.track != null);
    return entries.isEmpty ? null : artworkFor(entries.first.id);
  }

  Future<Uint8List?> _fetchArtwork(String id, String scope, String key) async {
    await mediaStorage!.ready;
    await mediaStorage!.refreshNetwork();
    if (_disposed ||
        _scope != scope ||
        !mediaStorage!.allows(DownloadPurpose.manual)) {
      return null;
    }
    final client = _createClient(_connection, key);
    try {
      return await client.fetchCover(id);
    } finally {
      client.close();
    }
  }

  bool get busy => _busy;
  bool get connected => _connected;
  String get status => _status;
  String? get error => _error;
  Uri get serverUri => _connection.uri;
  List<Playlist> get playlists => _playlists;
  DownloadManager? get downloads => _downloads;
  Future<void> get downloadShutdown => _downloadShutdown;

  void enqueueDownload(String id) {
    if (_disposed || _busy || _library == null || _downloads == null) return;
    final tracks = _library!.tracks(serverUri).where((track) => track.id == id);
    if (tracks.isNotEmpty) _downloads!.enqueue(tracks.first);
  }

  void appendToQueue(String id) {
    if (_disposed || _busy || playback == null || _library == null) return;
    final tracks = _library!.tracks(serverUri).where((track) => track.id == id);
    if (tracks.isEmpty || tracks.first.missing || tracks.first.removed) return;
    playback!.append(
      PlaybackItem(
        serverUri: serverUri,
        track: tracks.first,
        path: _library!.offlineSource(serverUri, id) ?? '',
      ),
    );
  }

  Future<void> playPlaylist(String playlistId, int entryIndex) {
    if (_disposed || _busy || playback == null || _library == null) {
      return Future.value();
    }
    final entries = entriesFor(playlistId);
    final items = <PlaybackItem>[];
    var selected = -1;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if ((!entry.downloaded && !entry.canDownload) || entry.track == null) {
        continue;
      }
      final path = _library!.offlineSource(serverUri, entry.id);
      if (index == entryIndex) selected = items.length;
      items.add(
        PlaybackItem(
          serverUri: serverUri,
          track: entry.track!,
          path: path ?? '',
        ),
      );
    }
    return selected < 0
        ? Future.value()
        : playback!.playQueue(items, index: selected);
  }

  Future<void> playDownloaded(String id) {
    if (_disposed || _busy || playback == null || _library == null) {
      return Future.value();
    }
    final path = _library!.offlineSource(serverUri, id);
    final tracks = _library!.tracks(serverUri).where((track) => track.id == id);
    if (tracks.isEmpty || tracks.first.missing || tracks.first.removed) {
      return Future.value();
    }
    return playback!.playQueue([
      PlaybackItem(serverUri: serverUri, track: tracks.first, path: path ?? ''),
    ]);
  }

  Future<RestoredConnection?> initialize() =>
      _initialization ??= _restoreConnection();

  Future<RestoredConnection?> _restoreConnection() async {
    final version = _version;
    try {
      final store = await _openStore();
      if (!_isCurrent(version)) return null;
      _initializeStorage(store);
      await mediaStorage!.ready;
      if (!_isCurrent(version)) return null;
      final connection = ServerConnection(
        store.selectedServer() ?? ServerConnection.defaultUri,
      );
      final apiKey = await loadSavedKey(connection.uri);
      if (!_isCurrent(version)) return null;
      _connection = connection;
      _apiKey = apiKey;
      if (apiKey != null) {
        store.bindCredentials(
          connection.uri,
          ServerConnection.credentialFingerprint(apiKey),
          adoptLegacy: true,
        );
        _scope =
            '${connection.key}:${ServerConnection.credentialFingerprint(apiKey)}';
        _readLibrary(store, connection);
        _status = '已加载本地曲库';
      } else if (playback != null) {
        _playbackSession = PlaybackSession(
          store: store,
          player: playback!,
          scope: 'preferences-only',
          serverUri: connection.uri,
          restoreQueue: false,
        );
      }
      notifyListeners();
      return (serverUri: connection.uri, apiKey: apiKey);
    } catch (_) {
      if (_isCurrent(version)) {
        _status = '无法恢复本地曲库，请检查连接设置';
        notifyListeners();
      }
      return null;
    }
  }

  Future<String?> loadSavedKey(Uri serverUri) async {
    try {
      final key = await _keyStore.readConnection(ServerConnection(serverUri));
      return _disposed ? null : key;
    } catch (_) {
      if (!_disposed && !_busy && !_connected) {
        _status = '无法读取系统安全存储';
        notifyListeners();
      }
      return null;
    }
  }

  Future<void> refresh() {
    final key = _apiKey;
    if (_disposed || key == null) return Future.value();
    return connectAndSync(_connection.uri.toString(), key);
  }

  List<PlaylistEntry> entriesFor(String playlistId) {
    final matches = _playlists.where((playlist) => playlist.id == playlistId);
    if (matches.isEmpty || _library == null || _disposed) return const [];
    return _library!.playlistEntries(serverUri, matches.first);
  }

  Future<void> connectAndSync(String serverText, String apiKey) {
    if (_disposed) return Future.value();
    if (mediaStorage?.busy == true) return Future.value();
    serverText = serverText.trim();
    apiKey = apiKey.trim();
    ServerConnection connection;
    try {
      if (serverText.isEmpty || apiKey.isEmpty) {
        _error = '请填写服务器地址和 API Key。';
        notifyListeners();
        return Future.value();
      }
      connection = ServerConnection(Uri.parse(serverText));
    } catch (_) {
      _error = '请使用有效的 HTTPS 服务器地址。';
      notifyListeners();
      return Future.value();
    }
    final scope =
        '${connection.key}:${ServerConnection.credentialFingerprint(apiKey)}';
    if (_busy && _scope == scope) return _syncFuture!;
    final version = ++_version;
    _activeClient?.close();
    if (_scope != scope) {
      _playbackSession?.dispose();
      _playbackSession = null;
      _playbackReset = playback?.clear() ?? Future.value();
      _playlists = const [];
      _library = null;
    }
    _scope = scope;
    _connection = connection;
    _apiKey = apiKey;
    _busy = true;
    _connected = false;
    _error = null;
    _status = '正在连接服务器…';
    final future = _synchronize(connection, apiKey, version);
    _syncFuture = future;
    notifyListeners();
    return future;
  }

  Future<void> _synchronize(
    ServerConnection connection,
    String apiKey,
    int version,
  ) async {
    PikmeloApiClient? client;
    LocalLibraryStore? store;
    try {
      client = _createClient(connection, apiKey);
      _activeClient = client;
      await _detachDownloads();
      await _playbackReset;
      _ensureCurrent(version);
      store = await _serializeConfiguration<LocalLibraryStore>(() async {
        _ensureCurrent(version);
        final opened = await _openStore();
        _ensureCurrent(version);
        final previousKey = await _keyStore.readConnection(connection);
        _ensureCurrent(version);
        opened.bindCredentials(
          connection.uri,
          ServerConnection.credentialFingerprint(apiKey),
          adoptLegacy: previousKey == apiKey,
        );
        opened.saveSelectedServer(connection.uri);
        _initializeStorage(opened);
        await mediaStorage!.ready;
        _ensureCurrent(version);
        _readLibrary(opened, connection, restoreDownloads: false);
        notifyListeners();
        return opened;
      });
      _ensureCurrent(version);
      final health = await client.checkHealth();
      _ensureCurrent(version);
      await _serializeConfiguration(() async {
        _ensureCurrent(version);
        await _keyStore.saveConnection(connection, apiKey);
        _ensureCurrent(version);
      });
      final result =
          await SyncService(
            client: client,
            store: store,
            serverUri: connection.uri,
          ).synchronize(
            isCurrent: () => _isCurrent(version),
            onCommitted: () async {
              await playback?.reconcile();
              final current = playback?.current;
              if (current != null &&
                  current.path.isNotEmpty &&
                  LibraryRepository(store!)
                          .offlineSource(current.serverUri, current.track.id) !=
                      current.path) {
                await playback?.releaseFile(current.path);
              }
            },
          );
      _ensureCurrent(version);
      _readLibrary(store, connection);
      _connected = true;
      _status = '已连接 · ${health['version'] ?? '服务器在线'} · 同步 ${result.pages} 页';
    } on SyncCancelledException {
      if (_isCurrent(version)) _status = '同步上下文已更新，请重试';
    } catch (error) {
      if (!_isCurrent(version)) return;
      if (error is PikmeloApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        store?.invalidateServer(connection.uri);
        await _metadataWork;
        await _embedded.idle;
        await playback?.reconcile();
        _playlists = const [];
      }
      _connected = false;
      if (store != null) _readLibrary(store, connection);
      _status = _playlists.isEmpty ? '连接失败' : '离线 · 显示本地曲库';
      _error = switch (error) {
        PikmeloApiException() => '${error.code}：${error.message}',
        TimeoutException() => '服务器请求超时，请重试。',
        SocketException() => '无法连接服务器，请检查网络。',
        FormatException() => '服务器响应格式异常。',
        _ => '连接或本地存储操作失败，请重试。',
      };
    } finally {
      client?.close();
      if (_isCurrent(version)) {
        _activeClient = null;
        _busy = false;
        notifyListeners();
      }
    }
  }

  Future<T> _serializeConfiguration<T>(Future<T> Function() operation) {
    final result = _configurationQueue.then((_) => operation());
    _configurationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return result;
  }

  void _readLibrary(
    LocalLibraryStore store,
    ServerConnection connection, {
    bool restoreDownloads = true,
  }) {
    _initializeStorage(store);
    _library = LibraryRepository(store);
    _playlists = _library!.playlists(connection.uri);
    final key = _apiKey;
    if (restoreDownloads && _downloads == null && key != null) {
      _downloads = DownloadManager(
        store: store,
        serverUri: connection.uri,
        createClient: () => _createClient(connection, key),
        cacheDirectory: _cacheDirectory,
        beforeRemove: playback?.releaseFile,
        storage: mediaStorage,
      );
      _downloads!.addListener(_downloadsChanged);
    }
    if (_playbackSession == null && playback != null && _scope != null) {
      _playbackSession = PlaybackSession(
        store: store,
        player: playback!,
        scope: _scope!,
        serverUri: connection.uri,
      );
    }
    _loadLocalMetadata(store, connection);
  }

  void _downloadsChanged() {
    if (!_disposed) {
      final storage = mediaStorage;
      if (storage != null && _library != null) {
        _loadLocalMetadata(storage.store, _connection);
      }
      notifyListeners();
      _trimCache();
    }
  }

  void _initializeStorage(LocalLibraryStore store) {
    if (mediaStorage != null) return;
    mediaStorage = MediaStorageController(store, networkReader: networkReader);
    mediaStorage!.addListener(_storageChanged);
    unawaited(updates?.initialize(mediaStorage!) ?? Future.value());
  }

  void _storageChanged() {
    if (_disposed) return;
    notifyListeners();
    final revision = mediaStorage?.networkRevision ?? -1;
    if (revision != _networkRevision) {
      _networkRevision = revision;
      _prefetchKey = null;
      _playbackChanged();
    }
  }

  void setPlaybackCacheLimit(int bytes) {
    mediaStorage?.setCacheLimit(bytes);
    _trimCache();
  }

  Future<String> _prepareSource(PlaybackItem item) async {
    final manager = _downloads;
    if (_disposed || item.serverUri != serverUri || manager == null) {
      throw const PlaybackPreparationException('曲库连接已更新，请重新选择曲目。');
    }
    try {
      final metadata = _library!
          .tracks(item.serverUri)
          .where(
            (track) =>
                track.id == item.track.id && !track.missing && !track.removed,
          );
      if (metadata.isEmpty) throw StateError('曲目授权已更新，请重新同步曲库。');
      final path = await manager.ensureReady(
        metadata.first,
        purpose: DownloadPurpose.playback,
      );
      if (_disposed || !identical(manager, _downloads)) {
        throw StateError('曲库连接已更新。');
      }
      return path;
    } catch (error) {
      throw PlaybackPreparationException(
        error is StateError ? error.message : '下载失败，请检查网络与媒体目录后重试。',
      );
    }
  }

  void _playbackChanged() {
    final player = playback;
    final manager = _downloads;
    if (_disposed ||
        player == null ||
        manager == null ||
        player.loading ||
        !player.state.playing) {
      return;
    }
    final next = player.upcoming;
    if (next == null || identical(next, player.current)) {
      _trimCache();
      return;
    }
    final key =
        '${identityHashCode(manager)}:${player.current?.track.id}:${next.track.id}:${mediaStorage?.mobilePolicy}';
    if (_prefetchKey == key) return;
    _prefetchKey = key;
    unawaited(
      manager
          .ensureReady(next.track, purpose: DownloadPurpose.prefetch)
          .then<void>(
            (_) => _trimCache(),
            onError: (Object _, StackTrace _) {},
          ),
    );
    _trimCache();
  }

  void _trimCache() {
    if (_disposed || _busy || _trimming != null || mediaStorage == null) return;
    _trimming = _runTrim().whenComplete(() => _trimming = null);
  }

  Future<void> _runTrim() async {
    final player = playback;
    final protected = <String>{};
    final currentId = player?.current?.track.id;
    final nextId = player?.upcoming?.track.id;
    for (final row in mediaStorage!.store.offlineTracks(
      authorizedOnly: false,
    )) {
      if (row['track_id'] == currentId || row['track_id'] == nextId) {
        protected.add(row['file_path'] as String);
      }
    }
    try {
      final removed = await mediaStorage!.trimCache(protected);
      for (final item in removed) {
        if (item.server == serverUri) _downloads?.forgetCompleted(item.id);
      }
    } catch (_) {
      /* A later completion retries cache cleanup. */
    }
  }

  Future<void> changeMediaDirectory(
    String? directory, {
    required bool migrate,
  }) => _serializeConfiguration(() async {
    if (_disposed || _busy || mediaStorage == null) return;
    _busy = true;
    notifyListeners();
    try {
      await playback?.clear();
      await _detachDownloads();
      await _trimming;
      await mediaStorage!.changeDirectory(directory, migrate: migrate);
    } finally {
      if (!_disposed) {
        _readLibrary(mediaStorage!.store, _connection);
        _busy = false;
        _prefetchKey = null;
        notifyListeners();
      }
    }
  });

  Future<void> _detachDownloads() {
    final manager = _downloads;
    _downloads = null;
    if (manager != null) {
      manager.removeListener(_downloadsChanged);
      _downloadShutdown = Future.wait([_downloadShutdown, manager.shutdown()])
          .then((_) {});
    }
    return _downloadShutdown;
  }

  bool _isCurrent(int version) => !_disposed && version == _version;

  void _ensureCurrent(int version) {
    if (!_isCurrent(version)) throw const SyncCancelledException();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playbackSession?.dispose();
    playback?.removeListener(_playbackChanged);
    _activeClient?.close();
    unawaited(playback?.clear() ?? Future.value());
    final closing = Future.wait([
      _detachDownloads(),
      _metadataWork ?? Future.value(),
      _embedded.idle,
    ]).then<void>((_) {});
    mediaStorage?.removeListener(_storageChanged);
    final storage = mediaStorage;
    if (storage != null) {
      _downloadShutdown = closing.then((_) async {
        if (_trimming != null) await _trimming;
        await storage.shutdown();
      });
    }
    super.dispose();
  }
}
