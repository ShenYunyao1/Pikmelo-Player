import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Container fields not exposed by the tag reader. Compressed formats have no
/// meaningful PCM bit depth unless a lossless codec explicitly supplies one.
Map<String, dynamic> readAudioProperties(File file) {
  final reader = file.openSync();
  try {
    final length = reader.lengthSync();
    final prefix = reader.readSync(64);
    if (prefix.length < 12) return {};
    String text(int start, int end) =>
        latin1.decode(prefix.sublist(start, end));
    if (text(0, 4) == 'fLaC' && prefix.length >= 26 && (prefix[4] & 127) == 0) {
      final packed = ByteData.sublistView(prefix).getUint64(18);
      return {
        'format': 'flac',
        'channels': ((packed >> 41) & 7) + 1,
        'bits_per_sample': ((packed >> 36) & 31) + 1,
      };
    }
    if (text(0, 4) == 'RIFF' && text(8, 12) == 'WAVE') {
      var offset = 12;
      while (offset + 8 <= length) {
        reader.setPositionSync(offset);
        final header = reader.readSync(8);
        final size = ByteData.sublistView(header).getUint32(4, Endian.little);
        if (size > length - offset - 8) break;
        if (latin1.decode(header.sublist(0, 4)) == 'fmt ' && size >= 16) {
          final data = ByteData.sublistView(
            reader.readSync(size > 40 ? 40 : size),
          );
          final encoding = data.getUint16(0, Endian.little);
          final containerBits = data.getUint16(14, Endian.little);
          final validBits = encoding == 0xfffe && size >= 40
              ? data.getUint16(18, Endian.little)
              : 0;
          return {
            'format': 'wav',
            'channels': data.getUint16(2, Endian.little),
            'bits_per_sample': validBits > 0 ? validBits : containerBits,
          };
        }
        offset += 8 + size + (size & 1);
      }
      return {'format': 'wav'};
    }
    if (text(4, 8) == 'ftyp') {
      final brand = text(8, 12).trim().toLowerCase();
      return {
        'format': switch (brand) {
          'm4a' || 'm4b' => brand,
          'qt' => 'mov',
          _ => 'mp4',
        },
        ..._mp4Audio(reader, 0, length, 0),
      };
    }
    if (text(0, 4) == 'OggS') {
      reader.setPositionSync(0);
      final head = reader.readSync(length < 65536 ? length : 65536);
      final data = latin1.decode(head);
      final opus = data.indexOf('OpusHead');
      if (opus >= 0 && opus + 10 <= head.length) {
        return {'format': 'opus', 'channels': head[opus + 9]};
      }
      final vorbis = data.indexOf('vorbis');
      return {
        'format': 'ogg',
        if (vorbis > 0 && vorbis + 11 <= head.length)
          'channels': head[vorbis + 10],
      };
    }
    var offset = 0;
    if (text(0, 3) == 'ID3') {
      offset =
          10 +
          prefix
              .sublist(6, 10)
              .fold(0, (value, byte) => (value << 7) | (byte & 127));
      if ((prefix[5] & 16) != 0) offset += 10;
    }
    if (offset >= length) return {};
    reader.setPositionSync(offset);
    final frames = reader.readSync(
      length - offset < 65536 ? length - offset : 65536,
    );
    for (var i = 0; i + 4 <= frames.length; i++) {
      if (frames[i] == 255 &&
          (frames[i + 1] & 224) == 224 &&
          (frames[i + 1] & 6) != 0 &&
          (frames[i + 1] & 24) != 8 &&
          (frames[i + 2] & 12) != 12 &&
          (frames[i + 2] >> 4) != 15) {
        final layer = (frames[i + 1] >> 1) & 3;
        return {
          'format': 'mp${4 - layer}',
          'channels': frames[i + 3] >> 6 == 3 ? 1 : 2,
        };
      }
    }
    return {};
  } finally {
    reader.closeSync();
  }
}

Map<String, dynamic> _mp4Audio(
  RandomAccessFile reader,
  int start,
  int end,
  int depth,
) {
  if (depth > 8) return {};
  var offset = start;
  while (offset + 8 <= end) {
    reader.setPositionSync(offset);
    final header = reader.readSync(8);
    var size = ByteData.sublistView(header).getUint32(0);
    final type = latin1.decode(header.sublist(4));
    var headerSize = 8;
    if (size == 1) {
      if (offset + 16 > end) break;
      size = ByteData.sublistView(reader.readSync(8)).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < headerSize || size > end - offset) break;
    if ([
          'mp4a',
          'alac',
          'fLaC',
          'Opus',
          'sowt',
          'twos',
          'lpcm',
        ].contains(type) &&
        size >= headerSize + 28) {
      reader.setPositionSync(offset + headerSize);
      final data = ByteData.sublistView(reader.readSync(28));
      return {
        'channels': data.getUint16(16),
        if (['sowt', 'twos', 'lpcm'].contains(type))
          'bits_per_sample': data.getUint16(18),
      };
    }
    if (['moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd'].contains(type)) {
      final result = _mp4Audio(
        reader,
        offset + headerSize + (type == 'stsd' ? 8 : 0),
        offset + size,
        depth + 1,
      );
      if (result.isNotEmpty) return result;
    }
    offset += size;
  }
  return {};
}
