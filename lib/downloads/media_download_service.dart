import 'dart:convert';
import 'dart:io';

import '../infrastructure/storage/media_files.dart';

import '../infrastructure/server/pikmelo_api_client.dart';
import '../infrastructure/storage/local_library_store.dart';
import '../library/models/track.dart';
import '../settings/media_storage_controller.dart';

class DownloadInterrupted implements Exception {
  const DownloadInterrupted();
}

class StoredMediaResult {
  const StoredMediaResult({
    required this.location,
    required this.etag,
    required this.bytesWritten,
  });
  final String location;
  final String? etag;
  final int bytesWritten;

  File get file {
    if (location.startsWith('content://')) {
      throw StateError('Use location to access an Android document URI.');
    }
    return File(location);
  }
}

class MediaDownloadService {
  MediaDownloadService({
    required this.client,
    required this.store,
    required this.cacheDirectory,
    required this.serverUri,
    this.storage,
  });

  static final Map<String, Future<StoredMediaResult>> _activeDownloads = {};

  final PikmeloApiClient client;
  final LocalLibraryStore store;
  final Directory cacheDirectory;
  final Uri serverUri;
  final MediaStorageController? storage;

  Future<StoredMediaResult> downloadTrack(
    Map<String, dynamic> track, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    bool Function()? canPublish,
  }) {
    final metadata = Track.fromJson(track);
    final id = metadata.id;
    final size = metadata.size;
    if (size == null || size < 0 || metadata.missing || metadata.removed) {
      throw const FormatException('Track metadata is missing its ID or size.');
    }

    final taskKey =
        '${identityHashCode(store)}:${LocalLibraryStore.serverKey(serverUri)}:$id';
    final activeDownload = _activeDownloads[taskKey];
    if (activeDownload != null) {
      return activeDownload;
    }

    final future = _downloadTrack(id, size, track, onProgress, canPublish);
    _activeDownloads[taskKey] = future;
    future.then<void>(
      (_) => _activeDownloads.remove(taskKey),
      onError: (Object error, StackTrace stackTrace) {
        _activeDownloads.remove(taskKey);
      },
    );
    return future;
  }

  Future<StoredMediaResult> _downloadTrack(
    String id,
    int size,
    Map<String, dynamic> track,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    bool Function()? canPublish,
  ) async {
    final task = store.downloadTask(serverUri, id);
    final generation = store.generationFor(serverUri);
    final sameGeneration =
        task != null &&
        (task['generation'] == null || task['generation'] == generation) &&
        File(task['file_path'] as String).existsSync();
    final resumeEtag = sameGeneration ? task['etag'] as String? : null;
    final serverDirectory = sameGeneration
        ? File(task['file_path'] as String).parent
        : Directory(
            '${cacheDirectory.path}${Platform.pathSeparator}${base64Url.encode(utf8.encode(LocalLibraryStore.serverKey(serverUri))).replaceAll('=', '')}${Platform.pathSeparator}generation-$generation',
          );
    final partialFile = File(
      '${serverDirectory.path}${Platform.pathSeparator}$id.part',
    );
    if (canPublish != null && !canPublish()) {
      throw const DownloadInterrupted();
    }
    store.savePartialEtag(
      serverUri,
      generation,
      id,
      resumeEtag,
      partialFile.path,
    );
    final result = await client.downloadMedia(
      trackId: id,
      directory: serverDirectory,
      expectedBytes: size,
      resumeEtag: resumeEtag,
      onProgress: onProgress,
      onEtag: (value) => store.savePartialEtag(
        serverUri,
        generation,
        id,
        value,
        partialFile.path,
      ),
    );
    String? previousPath;
    String? published;
    try {
      if (canPublish != null && !canPublish()) {
        throw const DownloadInterrupted();
      }
      published = await storage?.publish(result.file) ?? result.file.path;
      if (canPublish != null && !canPublish()) {
        throw const DownloadInterrupted();
      }
      previousPath = store.saveOfflineMedia(
        serverUri: serverUri,
        expectedGeneration: generation,
        trackId: id,
        track: track,
        file: result.file,
        etag: result.etag,
        location: published,
      );
    } catch (_) {
      if (published != null && published != result.file.path) {
        await store.files.delete(published);
      }
      if (await result.file.exists()) await result.file.delete();
      rethrow;
    }
    if (published != result.file.path && await result.file.exists()) {
      await result.file.delete();
    }
    if (previousPath != null && previousPath != published) {
      try {
        await store.files.delete(previousPath);
        store.completeFileDeletion(previousPath);
      } catch (_) {
        // A later sync retries the persisted cleanup after the file is released.
      }
    }
    return StoredMediaResult(
      location: published,
      etag: result.etag,
      bytesWritten: result.bytesWritten,
    );
  }

  static Future<Directory> defaultCacheDirectory() =>
      MediaFiles.defaultDirectory();
}
