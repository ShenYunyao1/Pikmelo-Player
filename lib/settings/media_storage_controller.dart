import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../infrastructure/storage/local_library_store.dart';
import '../infrastructure/storage/media_files.dart';

enum MobileDownloadPolicy { allow, playbackOnly, prohibit }

enum DownloadPurpose { manual, playback, prefetch }

class MediaStorageController extends ChangeNotifier {
  MediaStorageController(this.store, {this.networkReader}) {
    directory = store.setting('media_directory');
    final policy = store.setting('mobile_download_policy');
    mobilePolicy = MobileDownloadPolicy.values.firstWhere(
      (value) => value.name == policy,
      orElse: () => MobileDownloadPolicy.playbackOnly,
    );
    cacheLimit =
        int.tryParse(store.setting('playback_cache_limit') ?? '') ??
        1024 * 1024 * 1024;
    final journal = store.setting('media_migration');
    if (journal != null && journal.isNotEmpty) {
      _migration = Map<String, dynamic>.from(jsonDecode(journal) as Map);
    }
    ready = _initialize();
  }

  final LocalLibraryStore store;
  final Future<Map<String, bool>> Function()? networkReader;
  late final Future<void> ready;
  String? directory;
  late MobileDownloadPolicy mobilePolicy;
  late int cacheLimit;
  bool cellular = false;
  bool connected = false;
  bool networkKnown = false;
  int networkRevision = 0;
  bool busy = false;
  String? error;
  int migrated = 0;
  Map<String, dynamic>? _migration;
  Timer? _timer;
  bool _disposed = false;
  Future<void>? _working;
  Future<void>? _shutdown;
  Future<void>? _cacheCleanup;
  Future<void>? get cacheCleanup => _cacheCleanup;

  bool get migrationPending => _migration != null;
  int get cacheBytes => store
      .mediaInventory()
      .where((row) => row['pinned'] == 0)
      .fold(0, (total, row) => total + _size(row));
  String get directoryLabel => directory == null || directory!.isEmpty
      ? '应用默认目录'
      : Uri.decodeFull(directory!);

  int _size(Map<String, Object?> row) {
    final data = jsonDecode(row['track_data'] as String) as Map;
    final size = data['size'];
    if (size is int && size >= 0) return size;
    try {
      return store.files.length(row['file_path'] as String);
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _initialize() async {
    try {
      await store.files.refresh(
        store
            .offlineTracks(authorizedOnly: false)
            .map((row) => row['file_path'] as String),
      );
      if (_disposed) return;
      await refreshNetwork();
      if (networkReader == null && !_disposed) {
        if (Platform.isAndroid) {
          MediaFiles.android.setMethodCallHandler((call) async {
            if (call.method == 'networkChanged' && !_disposed) {
              _setNetwork(Map<String, bool>.from(call.arguments as Map));
            }
          });
        } else if (networkKnown) {
          _timer = Timer.periodic(
            const Duration(seconds: 3),
            (_) => unawaited(refreshNetwork()),
          );
        }
      }
    } catch (_) {
      error = '媒体目录无法访问，请重新选择目录。';
    }
    _notify();
  }

  Future<void> refreshNetwork() async {
    if (_disposed) return;
    try {
      final values = networkReader != null
          ? await networkReader!()
          : await (Platform.isAndroid ? MediaFiles.android : MediaFiles.windows)
                .invokeMapMethod<String, bool>('network');
      if (!_disposed) _setNetwork(values ?? const {});
    } on MissingPluginException {
      // Platform-free callers use DownloadManager without this policy adapter.
      networkKnown = false;
    } on PlatformException {
      networkKnown = false;
      _notify();
    }
  }

  void _setNetwork(Map<String, bool> values) {
    final online = values['connected'] ?? false;
    final mobile = values['cellular'] ?? false;
    if (networkKnown && online == connected && mobile == cellular) return;
    connected = online;
    cellular = mobile;
    networkKnown = true;
    networkRevision++;
    _notify();
  }

  bool allows(DownloadPurpose purpose) =>
      networkKnown &&
      connected &&
      (!cellular ||
          mobilePolicy == MobileDownloadPolicy.allow ||
          (mobilePolicy == MobileDownloadPolicy.playbackOnly &&
              purpose == DownloadPurpose.playback));

  void setMobilePolicy(MobileDownloadPolicy value) {
    if (mobilePolicy == value) return;
    mobilePolicy = value;
    networkRevision++;
    store.saveSetting('mobile_download_policy', value.name);
    _notify();
  }

  void setCacheLimit(int bytes) {
    if (bytes < 64 * 1024 * 1024) throw ArgumentError.value(bytes);
    cacheLimit = bytes;
    store.saveSetting('playback_cache_limit', '$bytes');
    _notify();
  }

  Future<Directory> downloadDirectory() async {
    await ready;
    if (migrationPending || busy) {
      throw const FileSystemException('目录迁移尚未完成，请先恢复迁移。');
    }
    final selected = directory;
    if (selected == null ||
        selected.isEmpty ||
        store.files.isDocument(selected)) {
      return MediaFiles.defaultDirectory();
    }
    final result = Directory(selected);
    await result.create(recursive: true);
    return result;
  }

  String _name() =>
      'pikmelo-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}.media';

  Future<String> publish(File source) async {
    final selected = directory;
    final destination = selected == null || selected.isEmpty
        ? (await MediaFiles.defaultDirectory()).path
        : selected;
    if (!store.files.isDocument(destination)) {
      var root = Directory(destination).absolute.uri.normalizePath().toString();
      var location = source.absolute.uri.normalizePath().toString();
      if (Platform.isWindows) {
        root = root.toLowerCase();
        location = location.toLowerCase();
      }
      if (location.startsWith(root)) return source.path;
    }
    return store.files.copy(
      source.path,
      destination,
      _name(),
      await source.length(),
    );
  }

  Future<void> changeDirectory(String? target, {required bool migrate}) {
    if (busy) return Future.error(StateError('媒体目录正在变更。'));
    final work = _change(target, migrate: migrate);
    _working = work;
    return work;
  }

  Future<void> _change(String? target, {required bool migrate}) async {
    busy = true;
    error = null;
    _notify();
    try {
      await ready;
      final destination =
          _migration?['destination'] as String? ??
          target ??
          (await MediaFiles.defaultDirectory()).path;
      if (_migration == null && migrate) {
        _migration = {
          'directory': target,
          'destination': destination,
          'files': store
              .offlineTracks(authorizedOnly: false)
              .map(
                (row) => {
                  'source': row['file_path'],
                  'target': null,
                  'verified': false,
                  'size': _size(row),
                },
              )
              .toList(),
        };
        _saveMigration();
      }
      await store.files.checkDirectory(destination);
      if (_migration != null) {
        final job = _migration!;
        final files = job['files'] as List;
        migrated = 0;
        for (final raw in files) {
          if (_disposed) throw StateError('目录迁移已暂停。');
          final entry = raw as Map;
          final source = entry['source'] as String;
          final size = entry['size'] as int;
          final sourceValid = await store.files.validate(source, size);
          if (!sourceValid &&
              store
                  .offlineTracks(authorizedOnly: false)
                  .any((row) => row['file_path'] == source)) {
            throw FileSystemException('迁移源文件无法访问，请恢复目录权限后重试。', source);
          }
          if (sourceValid) {
            var copied = entry['target'] as String?;
            if (entry['verified'] != true ||
                copied == null ||
                !await store.files.validate(copied, size)) {
              if (copied != null) await store.files.delete(copied);
              copied = await store.files.copy(
                source,
                job['destination'] as String,
                _name(),
                size,
                onCreated: (path) {
                  entry['target'] = path;
                  entry['verified'] = false;
                  _saveMigration();
                },
              );
              entry['verified'] = true;
              _saveMigration();
            }
            store.relocateMedia(source, copied);
            await store.files.delete(source);
            store.completeFileDeletion(source);
          }
          migrated++;
          _notify();
        }
        target = job['directory'] as String?;
      }
      directory = target;
      store.saveSetting('media_directory', target ?? '');
      _migration = null;
      _saveMigration();
    } catch (_) {
      error = '目录变更未完成，原有有效文件仍可读取。请检查权限和空间后重试迁移。';
      rethrow;
    } finally {
      busy = false;
      _working = null;
      _notify();
    }
  }

  void _saveMigration() => store.saveSetting(
    'media_migration',
    _migration == null ? '' : jsonEncode(_migration),
  );

  Future<List<({Uri server, String id})>> trimCache(
    Set<String> protectedPaths,
  ) {
    final work = _trimCache(protectedPaths);
    final settling = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _cacheCleanup = settling;
    settling.whenComplete(() {
      if (identical(_cacheCleanup, settling)) _cacheCleanup = null;
    });
    return work;
  }

  Future<List<({Uri server, String id})>> _trimCache(
    Set<String> protectedPaths,
  ) async {
    if (busy || migrationPending || _disposed) return const [];
    final removed = <({Uri server, String id})>[];
    final rows = store
        .mediaInventory()
        .where((row) => row['pinned'] == 0)
        .toList();
    var bytes = rows.fold(0, (total, row) => total + _size(row));
    for (final row in rows) {
      if (bytes <= cacheLimit || _disposed) break;
      final path = row['file_path'] as String;
      if (protectedPaths.contains(path)) continue;
      final server = Uri.parse(row['server_key'] as String);
      final id = row['track_id'] as String;
      if (store.mediaPinned(server, id)) continue;
      await store.files.delete(path);
      store.removeOfflineMedia(server, id);
      store.removeDownloadTask(server, id);
      bytes -= _size(row);
      removed.add((server: server, id: id));
    }
    _notify();
    return removed;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> shutdown() => _shutdown ??= _close();

  Future<void> _close() async {
    _disposed = true;
    _timer?.cancel();
    if (Platform.isAndroid && networkReader == null) {
      MediaFiles.android.setMethodCallHandler(null);
    }
    await ready;
    await _cacheCleanup;
    try {
      await _working;
    } catch (_) {
      /* The migration journal supports retry. */
    }
    super.dispose();
  }
}
