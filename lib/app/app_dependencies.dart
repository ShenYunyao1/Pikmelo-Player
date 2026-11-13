import '../infrastructure/server/pikmelo_api_client.dart';
import '../infrastructure/platform/system_media_service.dart';
import '../infrastructure/playback/media_kit_playback_engine.dart';
import '../shared/diagnostics.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_engine.dart';
import '../infrastructure/storage/api_key_store.dart';
import '../infrastructure/storage/local_library_store.dart';
import '../settings/connection_controller.dart';
import '../updates/update_controller.dart';

class AppDependencies {
  AppDependencies({
    ApiKeyStore? keyStore,
    Future<LocalLibraryStore> Function()? openStore,
    ApiClientFactory? createClient,
    PlaybackEngine Function()? createPlaybackEngine,
    this.networkReader,
    bool enableUpdates = true,
    UpdateController? updateController,
  }) : updates = enableUpdates ? updateController ?? UpdateController() : null,
       _keyStore = keyStore ?? ApiKeyStore(),
       _loadStore = openStore ?? (() => LocalLibraryStore.open()),
       _createPlaybackEngine =
           createPlaybackEngine ?? MediaKitPlaybackEngine.new,
       _createClient =
           createClient ??
           ((connection, apiKey) =>
               PikmeloApiClient(serverUri: connection.uri, apiKey: apiKey));

  final ApiKeyStore _keyStore;
  final UpdateController? updates;
  final Future<LocalLibraryStore> Function() _loadStore;
  final ApiClientFactory _createClient;
  final PlaybackEngine Function() _createPlaybackEngine;
  final Future<Map<String, bool>> Function()? networkReader;
  LocalLibraryStore? _openedStore;
  late final playback = PlaybackController(
    createEngine: _createPlaybackEngine,
    isAvailable: (item) {
      final elapsed = Stopwatch()..start();
      final track = _openedStore?.track(item.serverUri, item.track.id);
      final available =
          track != null &&
          track['id'] == item.track.id &&
          track['missing'] != true &&
          track['removed'] != true;
      if (Diagnostics.enabled) {
        Diagnostics.event('playback.availability', {
          'us': elapsed.elapsedMicroseconds,
          'allowed': available,
        });
      }
      return available;
    },
  );
  Future<LocalLibraryStore>? _storeFuture;
  bool _disposed = false;
  final _controllers = <ConnectionController>[];
  SystemMediaService? _systemMedia;

  Future<void> initializePlatformPlayback() async {
    _systemMedia ??= await SystemMediaService.attach(playback, onExit: dispose);
  }

  Future<LocalLibraryStore> openStore() {
    if (_disposed) {
      return Future.error(StateError('Application dependencies are disposed.'));
    }
    return _storeFuture ??= _openStore();
  }

  Future<LocalLibraryStore> _openStore() async {
    try {
      final store = await Future.sync(_loadStore);
      _openedStore = store;
      return store;
    } catch (_) {
      _storeFuture = null;
      rethrow;
    }
  }

  ConnectionController createConnectionController() {
    final controller = ConnectionController(
      keyStore: _keyStore,
      openStore: openStore,
      createClient: _createClient,
      playback: playback,
      networkReader: networkReader,
      updates: updates,
    );
    _controllers.add(controller);
    return controller;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await updates?.shutdown();
    for (final controller in _controllers) {
      controller.dispose();
    }
    playback.dispose();
    await playback.shutdown();
    await _systemMedia?.dispose();
    await Future.wait(
      _controllers.map((controller) => controller.downloadShutdown),
    );
    final opening = _storeFuture;
    if (opening == null) return;
    LocalLibraryStore store;
    try {
      store = await opening;
    } catch (_) {
      // The controller already reports an unsuccessful database open.
      return;
    }
    store.close();
  }
}
