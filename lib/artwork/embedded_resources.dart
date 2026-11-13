import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path_provider/path_provider.dart';

import '../infrastructure/storage/media_files.dart';
import 'audio_properties.dart';
import 'synchronized_lyrics.dart';

class EmbeddedResources {
  const EmbeddedResources({
    this.cover,
    this.lyrics,
    this.metadata = const {},
    this.readSucceeded = true,
  });
  final bool readSucceeded;
  final Uint8List? cover;
  final String? lyrics;
  final Map<String, dynamic> metadata;
}

Future<EmbeddedResources> readEmbeddedResources(
  String path,
  MediaFiles files, {
  Future<Directory> Function()? temporaryDirectory,
}) async {
  Directory? temporary;
  try {
    var localPath = path;
    if (files.isDocument(path)) {
      await files.validate(path);
      final root = await (temporaryDirectory ?? getTemporaryDirectory)();
      temporary = await root.createTemp('pikmelo-tags-');
      localPath = await files.copy(
        path,
        temporary.path,
        'audio.media',
        files.length(path),
      );
    }
    return await Isolate.run(() => parseEmbeddedResources(localPath));
  } catch (_) {
    return const EmbeddedResources(readSucceeded: false);
  } finally {
    if (temporary != null) await temporary.delete(recursive: true);
  }
}

EmbeddedResources parseEmbeddedResources(String path) {
  final tags = readMetadata(File(path), getImage: true);
  Map<String, dynamic> properties = {};
  try {
    properties = readAudioProperties(File(path));
  } catch (_) {
    /* Preserve readable tags. */
  }
  String? synchronized;
  try {
    synchronized = readSynchronizedLyrics(File(path));
  } catch (_) {
    /* Use readable text tags. */
  }
  final pictures = [...tags.pictures];
  pictures.sort(
    (a, b) => (a.pictureType == PictureType.coverFront ? 0 : 1).compareTo(
      b.pictureType == PictureType.coverFront ? 0 : 1,
    ),
  );
  final picture = pictures
      .where(
        (picture) =>
            picture.bytes.isNotEmpty && picture.bytes.length <= 8 * 1024 * 1024,
      )
      .firstOrNull;
  return EmbeddedResources(
    cover: picture?.bytes,
    lyrics: synchronized ?? tags.lyrics,
    metadata: {
      'title': tags.title,
      'artist': tags.artist,
      'album': tags.album,
      'genre': tags.genres.isEmpty ? null : tags.genres.join('; '),
      'duration_ms': tags.duration?.inMilliseconds,
      'bitrate_kbps': tags.bitrate == null
          ? null
          : (tags.bitrate! / 1000).round(),
      'sample_rate': tags.sampleRate,
      'channels': null,
      'bits_per_sample': null,
      'format': null,
      ...properties,
      'size': File(path).lengthSync(),
    },
  );
}

class EmbeddedResourceReader {
  final _pending = <String, Future<EmbeddedResources>>{};
  Future<void> _tail = Future.value();
  Future<void> get idle => _tail;
  Future<EmbeddedResources> read(String path, MediaFiles files) {
    final stat = files.isDocument(path) ? null : FileStat.statSync(path);
    final key = '$path|${stat?.size ?? files.length(path)}|${stat?.modified}';
    if (_pending.containsKey(key)) return _pending[key]!;
    if (_pending.length >= 16) _pending.remove(_pending.keys.first);
    final result = _tail.then(
      (_) => files.readSafely(path, () => readEmbeddedResources(path, files)),
    );
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending[key] = result;
    void forgetFailure() {
      if (identical(_pending[key], result)) _pending.remove(key);
    }

    result.then<void>((resource) {
      if (!resource.readSucceeded) forgetFailure();
    }, onError: (Object _, StackTrace _) => forgetFailure());
    return result;
  }
}
