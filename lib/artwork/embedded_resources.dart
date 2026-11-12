import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path_provider/path_provider.dart';

import '../infrastructure/storage/media_files.dart';

class EmbeddedResources {
  const EmbeddedResources({this.cover, this.lyrics});
  final Uint8List? cover;
  final String? lyrics;
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
    return const EmbeddedResources();
  } finally {
    if (temporary != null) await temporary.delete(recursive: true);
  }
}

EmbeddedResources parseEmbeddedResources(String path) {
  final tags = readMetadata(File(path), getImage: true);
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
  return EmbeddedResources(cover: picture?.bytes, lyrics: tags.lyrics);
}
