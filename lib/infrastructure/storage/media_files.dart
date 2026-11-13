import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Access to local paths and Android document URIs.
class MediaFiles {
  static Future<Directory> defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}PikmeloPlayer${Platform.pathSeparator}media',
    );
  }

  static const android = MethodChannel('pikmelo/media_storage');
  static const windows = MethodChannel('pikmelo/system_media');
  final _documentSizes = <String, int>{};
  final _reads = <String, Set<Future<void>>>{};
  final _deleting = <String>{};

  Future<T> readSafely<T>(String path, Future<T> Function() operation) {
    if (_deleting.contains(path)) {
      throw FileSystemException('Media is being deleted', path);
    }
    final work = Future.sync(operation);
    final done = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final reads = _reads.putIfAbsent(path, () => {});
    reads.add(done);
    done.then((_) {
      reads.remove(done);
      if (reads.isEmpty) _reads.remove(path);
    });
    return work;
  }

  int length(String path) =>
      isDocument(path) ? _documentSizes[path] ?? 0 : File(path).lengthSync();

  bool isDocument(String path) => path.startsWith('content://');

  bool exists(String path, [int? size]) {
    if (isDocument(path)) {
      final actual = _documentSizes[path];
      return actual != null && (size == null || actual == size);
    }
    try {
      final file = File(path);
      return file.existsSync() && (size == null || file.lengthSync() == size);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> validate(String path, [int? size]) async {
    if (isDocument(path)) {
      final values = await android.invokeMapMethod<String, dynamic>('stat', {
        'paths': [path],
      });
      _documentSizes.remove(path);
      final actual = values?[path];
      if (actual is int && actual >= 0) _documentSizes[path] = actual;
    }
    return exists(path, size);
  }

  Future<void> refresh(Iterable<String> paths) async {
    final documents = paths.where(isDocument).toSet().toList();
    if (documents.isEmpty) return;
    final values = await android.invokeMapMethod<String, dynamic>('stat', {
      'paths': documents,
    });
    for (final path in documents) {
      _documentSizes.remove(path);
      final size = values?[path];
      if (size is int && size >= 0) _documentSizes[path] = size;
    }
  }

  Future<void> delete(String path) async {
    _deleting.add(path);
    try {
      await Future.wait(_reads[path]?.toList() ?? <Future<void>>[]);
      if (isDocument(path)) {
        await android.invokeMethod<void>('delete', {'path': path});
        _documentSizes.remove(path);
      } else {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } finally {
      _deleting.remove(path);
    }
  }

  Future<String?> chooseDirectory() => (Platform.isAndroid ? android : windows)
      .invokeMethod<String>('chooseDirectory');

  Future<void> checkDirectory(String directory) async {
    final name =
        '.pikmelo-write-check-${DateTime.now().microsecondsSinceEpoch}';
    if (isDocument(directory)) {
      final path = await android.invokeMethod<String>('create', {
        'directory': directory,
        'name': name,
      });
      if (path == null) {
        throw const FileSystemException('Cannot write to the media directory.');
      }
      await delete(path);
    } else {
      final root = await Directory(directory).create(recursive: true);
      final probe = File('${root.path}${Platform.pathSeparator}$name');
      await probe.create(exclusive: true);
      await probe.delete();
    }
  }

  Future<String> copy(
    String source,
    String directory,
    String name,
    int expectedSize, {
    void Function(String path)? onCreated,
  }) async {
    if (isDocument(source) || isDocument(directory)) {
      final path = await android.invokeMethod<String>('create', {
        'directory': directory,
        'name': name,
      });
      if (path == null) throw const FileSystemException('Cannot copy media.');
      try {
        onCreated?.call(path);
        await android.invokeMethod<void>('copyTo', {
          'source': source,
          'target': path,
          'size': expectedSize,
        });
      } catch (_) {
        await delete(path);
        rethrow;
      }
      _documentSizes[path] = expectedSize;
      return path;
    }
    final target = File('$directory${Platform.pathSeparator}$name');
    await target.parent.create(recursive: true);
    await target.create(exclusive: true);
    try {
      onCreated?.call(target.path);
      await File(source).copy(target.path);
      if (await target.length() != expectedSize ||
          await sha256.bind(File(source).openRead()).first !=
              await sha256.bind(target.openRead()).first) {
        throw const FileSystemException('Media copy verification failed.');
      }
      return target.path;
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }
}
