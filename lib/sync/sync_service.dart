import 'dart:io';

import '../infrastructure/server/pikmelo_api_client.dart';
import '../infrastructure/server/sync_page.dart';
import '../infrastructure/storage/local_library_store.dart';

class SyncResult {
  const SyncResult({required this.pages, required this.restarted});

  final int pages;
  final bool restarted;
}

class SyncCancelledException implements Exception {
  const SyncCancelledException();
}

class SyncService {
  const SyncService({
    required this.client,
    required this.store,
    required this.serverUri,
    this.pageLimit = 100,
    this.maxRestarts = 3,
  });

  final PikmeloApiClient client;
  final LocalLibraryStore store;
  final Uri serverUri;
  final int pageLimit;
  final int maxRestarts;

  Future<SyncResult> synchronize({
    bool Function()? isCurrent,
    Future<void> Function()? onCommitted,
  }) async {
    _ensureCurrent(isCurrent);
    final generation = store.generationFor(serverUri);
    var cursor = store.cursorFor(serverUri);
    var restarted = false;
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      final pages = <PikmeloSyncPage>[];
      try {
        do {
          final page = await client.fetchSyncPage(
            cursor: cursor,
            limit: pageLimit,
          );
          _ensureCurrent(isCurrent);
          pages.add(page);
          cursor = page.cursor;
        } while (pages.last.hasMore);

        final staleDownloadPaths = store.applySyncPages(
          serverUri,
          pages,
          expectedGeneration: generation,
        );
        final authorizationGeneration = store.generationFor(serverUri);
        await onCommitted?.call();
        _ensureCurrent(isCurrent);
        for (final path in {
          ...staleDownloadPaths,
          ...store.pendingFileDeletions(),
        }) {
          try {
            _ensureCurrent(isCurrent);
            _ensureCurrent(isCurrent);
            await store.files.delete(path);
            store.completeFileDeletion(path);
          } on SyncCancelledException {
            rethrow;
          } catch (_) {
            continue;
          }
        }
        _ensureCurrent(isCurrent);
        await _restoreCachedMediaAuthorization(
          isCurrent,
          authorizationGeneration,
        );
        return SyncResult(pages: pages.length, restarted: restarted);
      } on PikmeloApiException catch (error) {
        if (error.code != 'SYNC_RESTART' || attempt == maxRestarts) {
          rethrow;
        }
        cursor = null;
        restarted = true;
      }
    }
    throw const HttpException('The library changed during every sync attempt.');
  }

  Future<void> _restoreCachedMediaAuthorization(
    bool Function()? isCurrent,
    int generation,
  ) async {
    if (store.generationFor(serverUri) != generation) {
      throw const SyncCancelledException();
    }
    final trackIDs = store.offlineTracksNeedingMediaAuthorization(serverUri);
    if (trackIDs.isEmpty) return;

    for (final trackID in trackIDs) {
      try {
        await client.checkMediaAccess(trackID);
        _ensureCurrent(isCurrent);
        if (store.generationFor(serverUri) != generation) {
          throw const SyncCancelledException();
        }
        store.authorizeOfflineMedia(serverUri, trackID, generation);
      } on SyncCancelledException {
        rethrow;
      } on PikmeloApiException catch (error) {
        if (error.statusCode == 404) continue;
        return;
      } catch (_) {
        return;
      }
    }
  }

  void _ensureCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) throw const SyncCancelledException();
  }
}
