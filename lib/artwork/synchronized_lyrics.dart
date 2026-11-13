import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

int _syncSafe(List<int> bytes) =>
    bytes.fold(0, (value, byte) => (value << 7) | (byte & 127));
Uint8List _unsynchronize(List<int> bytes) => Uint8List.fromList([
  for (var i = 0; i < bytes.length; i++)
    if (!(bytes[i] == 0 && i > 0 && bytes[i - 1] == 255)) bytes[i],
]);

/// Reads ID3 SYLT independently of the existing plain-text tag reader.
String? readSynchronizedLyrics(File file) {
  final reader = file.openSync();
  try {
    final header = reader.readSync(10);
    if (header.length < 10 ||
        ascii.decode(header.sublist(0, 3), allowInvalid: true) != 'ID3' ||
        ![2, 3, 4].contains(header[3])) {
      return null;
    }
    final version = header[3];
    final size = _syncSafe(header.sublist(6, 10));
    if (size > 32 * 1024 * 1024 || size > reader.lengthSync() - 10) return null;
    var tags = reader.readSync(size);
    if (version < 4 && header[5] & 128 != 0) tags = _unsynchronize(tags);
    var offset = 0;
    if (version >= 3 && header[5] & 64 != 0) {
      if (tags.length < 4) return null;
      offset = version == 4
          ? _syncSafe(tags.sublist(0, 4))
          : ByteData.sublistView(tags).getUint32(0) + 4;
    }
    final frameMs = _mpegFrameMilliseconds(reader, 10 + size);
    final headerSize = version == 2 ? 6 : 10;
    while (offset + headerSize <= tags.length) {
      final id = ascii.decode(
        tags.sublist(offset, offset + (version == 2 ? 3 : 4)),
        allowInvalid: true,
      );
      final length = version == 2
          ? (tags[offset + 3] << 16) |
                (tags[offset + 4] << 8) |
                tags[offset + 5]
          : version == 4
          ? _syncSafe(tags.sublist(offset + 4, offset + 8))
          : ByteData.sublistView(tags).getUint32(offset + 4);
      if (length <= 0 || length > tags.length - offset - headerSize) break;
      final flags = version == 2 ? 0 : tags[offset + 9];
      if ((id == 'SYLT' || id == 'SLT') &&
          length <= 2 * 1024 * 1024 &&
          (version == 4 ? flags & 12 == 0 : flags & 192 == 0)) {
        var payload = Uint8List.sublistView(
          tags,
          offset + headerSize,
          offset + headerSize + length,
        );
        if (version == 4 && (flags & 2 != 0 || header[5] & 128 != 0)) {
          payload = _unsynchronize(payload);
        }
        final prefix =
            (version == 4 && flags & 1 != 0 ? 4 : 0) +
            (version == 4 && flags & 64 != 0 || version == 3 && flags & 32 != 0
                ? 1
                : 0);
        if (prefix < payload.length) {
          final lyrics = _parse(payload.sublist(prefix), frameMs);
          if (lyrics != null) return lyrics;
        }
      }
      offset += headerSize + length;
    }
    return null;
  } finally {
    reader.closeSync();
  }
}

double? _mpegFrameMilliseconds(RandomAccessFile reader, int start) {
  reader.setPositionSync(start);
  final bytes = reader.readSync(65536);
  for (var i = 0; i + 4 <= bytes.length; i++) {
    final version = (bytes[i + 1] >> 3) & 3,
        layer = (bytes[i + 1] >> 1) & 3,
        rate = (bytes[i + 2] >> 2) & 3;
    if (bytes[i] != 255 ||
        bytes[i + 1] & 224 != 224 ||
        version == 1 ||
        layer == 0 ||
        rate == 3 ||
        bytes[i + 2] >> 4 == 0 ||
        bytes[i + 2] >> 4 == 15) {
      continue;
    }
    final sampleRate =
        [44100, 48000, 32000][rate] /
        (version == 3
            ? 1
            : version == 2
            ? 2
            : 4);
    final samples = layer == 3
        ? 384
        : layer == 2 || version == 3
        ? 1152
        : 576;
    return samples * 1000 / sampleRate;
  }
  return null;
}

String? _parse(Uint8List bytes, double? frameMs) {
  if (bytes.length < 7 ||
      bytes[0] > 3 ||
      ![1, 2].contains(bytes[4]) ||
      bytes[5] > 2) {
    return null;
  }
  final encoding = bytes[0], wide = encoding == 1 || encoding == 2;
  int endAt(int start) {
    for (var i = start; i < bytes.length - (wide ? 1 : 0); i += wide ? 2 : 1) {
      if (bytes[i] == 0 && (!wide || bytes[i + 1] == 0)) return i;
    }
    return -1;
  }

  final descriptionEnd = endAt(6);
  if (descriptionEnd < 0) return null;
  final little =
      encoding == 1 && bytes.length > 7 && bytes[6] == 255 && bytes[7] == 254;
  String decode(List<int> data) {
    if (encoding == 0) return latin1.decode(data);
    if (encoding == 3) return utf8.decode(data, allowMalformed: true);
    var start = 0, le = little;
    if (data.length >= 2 &&
        (data[0] == 255 && data[1] == 254 ||
            data[0] == 254 && data[1] == 255)) {
      le = data[0] == 255;
      start = 2;
    }
    return String.fromCharCodes([
      for (var i = start; i + 1 < data.length; i += 2)
        le ? data[i] | (data[i + 1] << 8) : (data[i] << 8) | data[i + 1],
    ]);
  }

  final parts = <({int time, String text})>[];
  var offset = descriptionEnd + (wide ? 2 : 1);
  while (offset < bytes.length) {
    final end = endAt(offset), terminator = wide ? 2 : 1;
    if (end < 0 || end + terminator + 4 > bytes.length) return null;
    final text = decode(bytes.sublist(offset, end)).replaceAll('\r', '');
    final time = ByteData.sublistView(bytes).getUint32(end + terminator);
    parts.add((time: time, text: text));
    if (parts.length > 20000) return null;
    offset = end + terminator + 4;
  }
  if (!parts.any((part) => part.text.trim().isNotEmpty)) return null;
  if (bytes[4] == 1 && frameMs == null) {
    return parts.map((part) => part.text).join('\n').trim();
  }
  String stamp(int value) {
    final ms = bytes[4] == 2 ? value : (value * frameMs!).round();
    return '[${(ms ~/ 60000).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}]';
  }

  if (!parts.any((part) => part.text.contains('\n'))) {
    return parts
        .map((part) => '${stamp(part.time)}${part.text.trim()}')
        .join('\n');
  }
  final lines = <String>[];
  var text = '', time = 0;
  for (final part in parts) {
    final fragments = part.text.split('\n');
    for (var i = 0; i < fragments.length; i++) {
      if (i > 0) {
        if (text.trim().isNotEmpty) lines.add('${stamp(time)}${text.trim()}');
        text = '';
      }
      if (text.isEmpty) time = part.time;
      text += fragments[i];
    }
  }
  if (text.trim().isNotEmpty) lines.add('${stamp(time)}${text.trim()}');
  return lines.join('\n');
}
