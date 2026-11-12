import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../infrastructure/server/pikmelo_api_client.dart';
import '../infrastructure/storage/local_library_store.dart';
import '../library/models/track.dart';
import '../library/library_repository.dart';
import '../settings/media_storage_controller.dart';
import 'media_download_service.dart';
import 'models/download_task.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.store,
    required this.serverUri,
    required this.createClient,
    this.beforeRemove,
    this.storage,
    Future<Directory> Function()? cacheDirectory,
  }) : _cacheDirectory =
           cacheDirectory ??
           storage?.downloadDirectory ??
           MediaDownloadService.defaultCacheDirectory {
    _restore();
    storage?.addListener(_networkChanged);
  }

  final LocalLibraryStore store;
  final Uri serverUri;
  final PikmeloApiClient Function() createClient;
  final Future<void> Function(String path)? beforeRemove;
  final MediaStorageController? storage;
  final _purposes = <String, DownloadPurpose>{};
  final _waiters = <String, Completer<String>>{};
  String? _preparingId;
  int _preparationRevision = 0;
  final Future<Directory> Function() _cacheDirectory;
  final _tasks = <String, DownloadTask>{};
  final _changing = <String>{};
  final _mutations = <String, Future<void>>{};
  PikmeloApiClient? _client;
  String? _activeId;
  Future<void>? _activeRun;
  Future<void>? _worker;
  Future<void>? _shutdown;
  bool _closed = false;
  bool _notifierDisposed = false;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);

  void _restore() {
    final tracks = {
      for (final json in store.tracks(serverUri))
        json['id'] as String: Track.fromJson(json),
    };
    final offline = {
      for (final row in store.offlineTracks(
        serverUri: serverUri,
        authorizedOnly: false,
      ))
        row['track_id'] as String: row,
    };
    final partial = {
      for (final row in store.downloadTasks(serverUri))
        row['track_id'] as String: row,
    };
    final queued = {
      for (final row in store.downloadQueue(serverUri))
        row['track_id'] as String: row,
    };
    final ids = {...queued.keys, ...partial.keys, ...offline.keys};
    for (final id in ids) {
      final track = tracks[id];
      if (track == null || track.missing || track.removed) continue;
      final cached = offline[id];
      final valid =
          cached != null &&
          cached['authorized'] == 1 &&
          _validFile(cached['file_path'] as String, track.size);
      if (!queued.containsKey(id) && !partial.containsKey(id) && !valid) {
        continue;
      }
      final row = queued[id];
      var status = DownloadStatus.values.firstWhere(
        (status) => status.name == row?['status'],
        orElse: () => DownloadStatus.paused,
      );
      var error = row?['error'] as String?;
      if (valid) {
        status = DownloadStatus.completed;
        error = null;
      } else if (status == DownloadStatus.completed) {
        status = DownloadStatus.failed;
        error = '本地文件缺失、大小不符或授权已失效，请重新下载。';
        // Document providers can be unavailable while shared storage is mounting.
        // Retain server authorization so a later successful stat can restore playback.
        if (cached != null &&
            !store.files.isDocument(cached['file_path'] as String)) {
          store.revokeOfflineMedia(serverUri, id);
        }
      } else if (status == DownloadStatus.downloading ||
          status == DownloadStatus.queued) {
        status = DownloadStatus.paused;
      }
      final path = partial[id]?['file_path'] as String?;
      final received = valid
          ? track.size ?? 0
          : path != null && File(path).existsSync()
          ? File(path).lengthSync()
          : 0;
      _set(
        DownloadTask(
          track: track,
          status: status,
          received: received,
          error: error,
        ),
      );
    }
  }

  bool _validFile(String path, int? size) {
    return store.files.exists(path, size);
  }

  void enqueue(
    Track track, {
    DownloadPurpose purpose = DownloadPurpose.manual,
  }) {
    if (_closed || _changing.contains(track.id)) return;
    final cleanup = storage?.cacheCleanup;
    if (cleanup != null) {
      unawaited(cleanup.then((_) => enqueue(track, purpose: purpose)));
      return;
    }
    if (track.size == null ||
        track.size! < 0 ||
        track.missing ||
        track.removed) {
      throw const FormatException('Track metadata cannot be downloaded.');
    }
    store.retainMedia(
      serverUri,
      track.id,
      pinned: purpose == DownloadPurpose.manual,
    );
    final previous = _purposes[track.id];
    final existing = _tasks[track.id];
    final running =
        existing?.status == DownloadStatus.downloading ||
        existing?.status == DownloadStatus.queued;
    if (!running ||
        previous == null ||
        _priority(purpose) < _priority(previous)) {
      _purposes[track.id] = purpose;
    }
    if (existing?.status == DownloadStatus.downloading ||
        existing?.status == DownloadStatus.queued) {
      return;
    }
    var received = existing?.received ?? 0;
    if (existing?.status == DownloadStatus.completed) {
      final cached = store
          .offlineTracks(serverUri: serverUri)
          .where((row) => row['track_id'] == track.id);
      if (cached.isNotEmpty &&
          _validFile(cached.first['file_path'] as String, track.size)) {
        return;
      }
      store.revokeOfflineMedia(serverUri, track.id);
      received = 0;
    }
    _set(
      DownloadTask(
        track: track,
        status: DownloadStatus.queued,
        received: received,
      ),
    );
    _worker ??= _drain();
  }

  void resume(String id) {
    final task = _tasks[id];
    if (task != null) enqueue(task.track);
  }

  Future<void> _drain() async {
    try {
      while (!_closed) {
        final queued =
            _tasks.values
                .where(
                  (task) =>
                      task.status == DownloadStatus.queued &&
                      !_changing.contains(task.track.id),
                )
                .toList()
              ..sort(
                (a, b) =>
                    _priority(_purpose(a.track.id))
                        .compareTo(_priority(_purpose(b.track.id))),
              );
        if (queued.isEmpty) return;
        final task = queued.first;
        _activeId = task.track.id;
        _activeRun = _download(task);
        await _activeRun;
        _activeId = null;
        _activeRun = null;
        _client = null;
      }
    } finally {
      _worker = null;
    }
  }

  Future<void> _download(DownloadTask task) async {
    final id = task.track.id;
    final generation = store.generationFor(serverUri);
    bool active() =>
        !_closed &&
        _tasks[id]?.status == DownloadStatus.downloading &&
        store.generationFor(serverUri) == generation;
    try {
      await storage?.ready;
      await storage?.refreshNetwork();
      if (_closed || _tasks[id]?.status != DownloadStatus.queued) return;
      if (storage != null && !storage!.allows(_purpose(id))) {
        _set(
          task.withState(
            DownloadStatus.paused,
            error: '当前网络策略禁止此下载，请连接 Wi-Fi 或调整设置。',
          ),
        );
        return;
      }
      _client = createClient();
      _set(task.withState(DownloadStatus.downloading));
      final directory = await _cacheDirectory();
      if (!active()) throw const DownloadInterrupted();
      var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      await MediaDownloadService(
        client: _client!,
        store: store,
        serverUri: serverUri,
        cacheDirectory: directory,
        storage: storage,
      ).downloadTrack(
        task.track.toJson(),
        canPublish: active,
        onProgress: (received, total) {
          if (!active()) throw const DownloadInterrupted();
          final updated = task.withState(
            DownloadStatus.downloading,
            received: received,
          );
          _tasks[id] = updated;
          if (DateTime.now().difference(lastUpdate).inMilliseconds >= 200 ||
              received == total) {
            lastUpdate = DateTime.now();
            _set(updated);
          }
        },
      );
      if (!_closed && _tasks[id]?.status == DownloadStatus.downloading) {
        _set(
          task.withState(DownloadStatus.completed, received: task.track.size),
        );
      }
    } catch (error) {
      if (!_closed && _tasks[id]?.status == DownloadStatus.downloading) {
        final message = switch (error) {
          FileSystemException() => '本地文件操作失败，请检查存储空间或文件权限。',
          PikmeloApiException() => '下载失败（${error.statusCode}），可重试或重新同步授权。',
          _ => '下载中断，可继续或重试。',
        };
        _set(_tasks[id]!.withState(DownloadStatus.failed, error: message));
      }
    } finally {
      _client?.close();
    }
  }

  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null || _closed) return;
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      _set(task.withState(DownloadStatus.paused));
      if (_activeId == id) {
        _client?.close();
        await _activeRun;
      }
    }
  }

  Future<void> cancel(String id) => _mutate(id, removeCompleted: false);
  Future<void> remove(String id) => _mutate(id, removeCompleted: true);

  Future<void> _mutate(String id, {required bool removeCompleted}) {
    if (_closed) return Future.value();
    final pending = _mutations[id];
    if (pending != null) return pending;
    final operation = _delete(id, removeCompleted: removeCompleted);
    _mutations[id] = operation;
    operation.then<void>(
      (_) {
        _mutations.remove(id);
      },
      onError: (Object error, StackTrace stack) {
        _mutations.remove(id);
      },
    );
    return operation;
  }

  Future<void> _delete(String id, {required bool removeCompleted}) async {
    if (_closed || !_changing.add(id)) return;
    try {
      await pause(id);
      final partial =
          store.downloadTask(serverUri, id)?['file_path'] as String?;
      final paths = <String>[?partial];
      if (removeCompleted) {
        paths.addAll(
          store
              .offlineTracks(serverUri: serverUri, authorizedOnly: false)
              .where((row) => row['track_id'] == id)
              .map((row) => row['file_path'] as String),
        );
        store.revokeOfflineMedia(serverUri, id);
      }
      for (final path in paths) {
        await beforeRemove?.call(path);
        await store.files.delete(path);
      }
      if (removeCompleted) store.removeOfflineMedia(serverUri, id);
      store.removeDownloadTask(serverUri, id);
      _tasks.remove(id);
      if (!_closed) notifyListeners();
    } catch (_) {
      final task = _tasks[id];
      if (task != null && !_closed) {
        _set(
          task.withState(DownloadStatus.failed, error: '删除失败，请检查文件是否被占用后重试。'),
        );
      }
    } finally {
      _changing.remove(id);
    }
  }

  void _set(DownloadTask task) {
    _tasks[task.track.id] = task;
    try {
      store.saveDownloadQueue(
        serverUri,
        task.track.id,
        task.status.name,
        task.received,
        task.error,
      );
    } on SqliteException {
      _tasks[task.track.id] = task.withState(
        DownloadStatus.failed,
        error: '无法保存下载任务，请检查存储空间后重试。',
      );
    }
    if (!_closed) notifyListeners();
    final effective = _tasks[task.track.id]!;
    final waiter = _waiters[task.track.id];
    if (waiter != null && !waiter.isCompleted) {
      if (effective.status == DownloadStatus.completed) {
        final path = LibraryRepository(store)
            .offlineSource(serverUri, task.track.id);
        if (path != null) {
          waiter.complete(path);
        } else {
          waiter.completeError(StateError('下载文件无法读取。'));
        }
      } else if (effective.status == DownloadStatus.failed ||
          effective.status == DownloadStatus.paused) {
        waiter.completeError(StateError(effective.error ?? '下载已暂停。'));
      }
    }
  }

  DownloadPurpose _purpose(String id) =>
      _purposes[id] ?? DownloadPurpose.manual;
  int _priority(DownloadPurpose purpose) => switch (purpose) {
    DownloadPurpose.playback => 0,
    DownloadPurpose.manual => 1,
    DownloadPurpose.prefetch => 2,
  };

  Future<String> ensureReady(
    Track track, {
    required DownloadPurpose purpose,
  }) async {
    final revision = _preparationRevision;
    await storage?.ready;
    await storage?.cacheCleanup;
    if (_closed) throw StateError('下载管理已关闭。');
    if (purpose == DownloadPurpose.playback &&
        revision != _preparationRevision) {
      throw StateError('播放准备已取消。');
    }
    final path = LibraryRepository(store).offlineSource(serverUri, track.id);
    if (path != null && await store.files.validate(path, track.size)) {
      store.retainMedia(
        serverUri,
        track.id,
        pinned: purpose == DownloadPurpose.manual,
      );
      return path;
    }
    final existing = _waiters[track.id];
    if (existing != null && !existing.isCompleted) {
      if (purpose == DownloadPurpose.manual) enqueue(track, purpose: purpose);
      if (purpose == DownloadPurpose.playback) {
        _purposes[track.id] = purpose;
        _preparingId = track.id;
        await _prioritize(track.id);
      }
      return existing.future;
    }
    final waiter = Completer<String>();
    _waiters[track.id] = waiter;
    // Attach a listener before an interruption can complete the future.
    final result = waiter.future.then((value) => value);
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    if (purpose == DownloadPurpose.playback) _preparingId = track.id;
    try {
      enqueue(track, purpose: purpose);
      if (purpose == DownloadPurpose.playback) await _prioritize(track.id);
      return await result;
    } finally {
      if (identical(_waiters[track.id], waiter)) _waiters.remove(track.id);
      if (_preparingId == track.id) _preparingId = null;
    }
  }

  void cancelPreparation() {
    _preparationRevision++;
    final id = _preparingId;
    _preparingId = null;
    if (id == null) return;
    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('播放准备已取消。'));
    }
    if (!store.mediaPinned(serverUri, id)) unawaited(pause(id));
  }

  Future<void> _prioritize(String id) async {
    final previous = _activeId;
    if (previous == null || previous == id) return;
    final purpose = _purpose(previous);
    await pause(previous);
    final background = _tasks[previous];
    if (background != null && !_closed) {
      enqueue(background.track, purpose: purpose);
    }
  }

  void forgetCompleted(String id) {
    if (_tasks[id]?.status == DownloadStatus.completed) {
      _tasks.remove(id);
      if (!_closed) notifyListeners();
    }
  }

  void _networkChanged() {
    final id = _activeId;
    if (id != null && storage != null && !storage!.allows(_purpose(id))) {
      unawaited(pause(id));
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();

  Future<void> _close() async {
    storage?.removeListener(_networkChanged);
    cancelPreparation();
    _closed = true;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('下载管理已关闭。'));
    }
    _waiters.clear();
    _client?.close();
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        _set(task.withState(DownloadStatus.paused));
      }
    }
    await Future.wait([?_worker, ..._mutations.values]);
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(shutdown());
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}
