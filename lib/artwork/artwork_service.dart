import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../infrastructure/storage/media_files.dart';
import 'embedded_resources.dart';

class ArtworkService {
  ArtworkService({
    this.readEmbedded = readEmbeddedResources,
    this.cacheDirectory,
  });
  final Future<EmbeddedResources> Function(String, MediaFiles) readEmbedded;
  final Future<Directory> Function()? cacheDirectory;
  final _requests = <String, Future<Uint8List?>>{};
  final _retryAfter = <String, DateTime>{};
  Future<void> _pending = Future.value();

  Future<Uint8List?> load({
    required String scope,
    required String revision,
    required String? path,
    required String? coverId,
    required MediaFiles files,
    required Future<Uint8List?> Function(String) fetchCover,
    required bool Function() allowed,
    String retryToken = '',
  }) {
    if (!allowed()) return Future.value();
    final stat = path != null && !files.isDocument(path)
        ? FileStat.statSync(path)
        : null;
    final key = sha256
        .convert(
          utf8.encode('$scope|$revision|$path|${stat?.modified}|${stat?.size}'),
        )
        .toString();
    final serverKey = sha256.convert(utf8.encode('$scope|$coverId')).toString();
    final requestKey = '$key|$coverId|$retryToken';
    final existing = _requests[requestKey];
    final retryAfter = _retryAfter[requestKey];
    if (existing != null &&
        (retryAfter == null || DateTime.now().isBefore(retryAfter))) {
      return existing;
    }
    if (_requests.length >= 64) {
      final oldest = _requests.keys.first;
      _requests.remove(oldest);
      _retryAfter.remove(oldest);
    }
    _retryAfter.remove(requestKey);
    final result = _pending.then(
      (_) => _load(key, serverKey, path, coverId, files, fetchCover, allowed),
    );
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _requests[requestKey] = result;
    result.then<void>((bytes) {
      if (bytes == null && identical(_requests[requestKey], result)) {
        _retryAfter[requestKey] = DateTime.now().add(
          const Duration(minutes: 1),
        );
      }
    }, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List?> _load(
    String key,
    String serverKey,
    String? path,
    String? coverId,
    MediaFiles files,
    Future<Uint8List?> Function(String) fetchCover,
    bool Function() allowed,
  ) async {
    if (!allowed()) return null;
    try {
      final directory =
          await cacheDirectory?.call() ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/PikmeloPlayer/artwork',
          );
      final cached = File('${directory.path}/embedded-$key');
      final localCached = await _readCached(cached);
      if (localCached != null && allowed()) return localCached;
      Uint8List? bytes;
      if (path != null && path.isNotEmpty) {
        try {
          bytes = (await readEmbedded(path, files)).cover;
        } catch (_) {
          /* Try server artwork. */
        }
      }
      if (bytes != null && await validImage(bytes) && allowed()) {
        await _save(cached, bytes);
        return allowed() ? bytes : null;
      }
      if (coverId == null || coverId.isEmpty || !allowed()) return null;
      final serverFile = File('${directory.path}/server-$serverKey');
      bytes = await _readCached(serverFile);
      if (bytes != null && allowed()) return bytes;
      bytes = await fetchCover(coverId);
      if (bytes == null || !await validImage(bytes) || !allowed()) return null;
      await _save(serverFile, bytes);
      return allowed() ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readCached(File file) async {
    if (!await file.exists()) return null;
    if (await file.length() <= 8 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      if (await validImage(bytes)) return bytes;
    }
    await file.delete();
    return null;
  }

  Future<void> _save(File file, Uint8List bytes) async {
    File? partial;
    try {
      await file.parent.create(recursive: true);
      partial = File(
        '${file.path}.part-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
      final entries = await file.parent
          .list()
          .where((entry) => entry is File && !entry.path.contains('.part-'))
          .cast<File>()
          .toList();
      final stats = <File, FileStat>{};
      var total = 0;
      for (final entry in entries) {
        final stat = await entry.stat();
        stats[entry] = stat;
        total += stat.size;
      }
      entries.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
      for (final entry in entries) {
        if (total <= 64 * 1024 * 1024) break;
        await entry.delete();
        total -= stats[entry]!.size;
      }
    } catch (_) {
      /* A cache failure must not hide a valid cover. */
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {
        /* Cache cleanup must not interrupt artwork display. */
      }
    }
  }

  static Future<bool> validImage(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return false;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 512);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return true;
    } catch (_) {
      return false;
    } finally {
      codec?.dispose();
    }
  }
}
